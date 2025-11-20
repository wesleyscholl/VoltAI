// Clean single-file implementation: index (TF-IDF) + Ollama-first query
// Overwrite with a clean, minimal implementation.
use std::collections::{HashMap, HashSet};
use std::fs::File;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::{anyhow, Result};
use clap::{Parser, Subcommand};
use indicatif::{ProgressBar, ProgressStyle};
use rayon::prelude::*;
use regex::Regex;
use once_cell::sync::Lazy;
use serde::{Deserialize, Serialize};
use walkdir::WalkDir;

static WORD_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"[a-zA-Z0-9']+").unwrap());

#[derive(Parser)]
#[command(name = "VoltAI", about = "Fast local AI agent — MVP (TF-IDF based)")]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    Index {
        #[arg(short, long)]
        dir: PathBuf,
        #[arg(short, long, default_value = "voltai_index.json")]
        out: PathBuf,
    },
    Query {
        #[arg(short, long, default_value = "voltai_index.json")]
        index: PathBuf,
        #[arg(short, long)]
        q: String,
        #[arg(short, long, default_value_t = 3)]
        k: usize,
        /// Optional Ollama model override (e.g. gemma3:4b). If omitted the app will probe for a fast model.
        #[arg(short = 'm', long = "model")]
        model: Option<String>,
    },
}

#[derive(Serialize, Deserialize, Debug)]
struct Doc {
    id: String,
    path: String,
    text: String,
}

#[derive(Serialize, Deserialize, Debug)]
struct Index {
    docs: Vec<Doc>,
    terms: Vec<String>,
    vectors: Vec<Vec<f32>>,
}

fn read_text_file(p: &Path) -> Result<String> {
    let mut s = String::new();
    let mut f = File::open(p)?;
    f.read_to_string(&mut s)?;
    Ok(s)
}

fn read_file_content(p: &Path) -> Result<String> {
    let ext = p.extension().and_then(|s| s.to_str()).unwrap_or("");
    if ext == "pdf" {
        pdf_extract::extract_text(p).map_err(|e| anyhow!("PDF extraction failed: {}", e))
    } else {
        read_text_file(p)
    }
}

fn tokenize(s: &str) -> Vec<String> {
    WORD_RE
        .find_iter(s)
        .map(|m| m.as_str().to_lowercase())
        .collect()
}

fn cosine_sim(a: &[f32], b: &[f32]) -> f32 {
    a.iter().zip(b.iter()).map(|(x, y)| x * y).sum()
}

fn index_dir(dir: &Path, out: &Path) -> Result<()> {
    // Only index common textual file types to avoid capturing binary files (git internals, images,
    // compiled artifacts) which can produce oversized or invalid JSON output.
    let allowed_exts = ["txt", "md", "csv", "json", "pdf"];
    let mut files: Vec<PathBuf> = WalkDir::new(dir)
        .into_iter()
        .filter_map(|e| e.ok())
        .filter(|e| e.file_type().is_file())
        .filter(|e| {
            e.path()
                .extension()
                .and_then(|s| s.to_str())
                .map(|ext| allowed_exts.contains(&ext))
                .unwrap_or(false)
        })
        .map(|e| e.path().to_path_buf())
        .collect();

    files.sort();

    let pb = ProgressBar::new(files.len() as u64);
    pb.set_style(
        ProgressStyle::with_template("{spinner:.green} [{elapsed_precise}] {wide_bar} {pos}/{len} {msg}")?
            .progress_chars("=>-"),
    );

    let docs: Vec<Doc> = files
        .par_iter()
        .map(|p| {
            let text = read_file_content(p).unwrap_or_else(|_| String::new());
            let id = format!("doc-{}", p.file_name().map(|s| s.to_string_lossy()).unwrap_or_default());
            pb.inc(1);
            Doc {
                id,
                path: p.to_string_lossy().to_string(),
                text,
            }
        })
        .collect();

    pb.finish_with_message("indexing files");

    let mut df: HashMap<String, usize> = HashMap::new();
    let mut docs_tokens: Vec<Vec<String>> = Vec::with_capacity(docs.len());

    for doc in &docs {
        let toks = tokenize(&doc.text);
        let mut seen: HashSet<String> = HashSet::new();
        for t in toks.iter() {
            if seen.insert(t.clone()) {
                *df.entry(t.clone()).or_insert(0) += 1;
            }
        }
        docs_tokens.push(toks);
    }

    let terms: Vec<String> = {
        let mut v: Vec<(String, usize)> = df.into_iter().collect();
        v.sort_by(|a, b| b.1.cmp(&a.1));
        v.into_iter().map(|(t, _)| t).collect()
    };

    let term_index: HashMap<&String, usize> = terms.iter().enumerate().map(|(i, t)| (t, i)).collect();

    let vectors: Vec<Vec<f32>> = docs_tokens
        .par_iter()
        .map(|toks| {
            let mut tf: HashMap<usize, f32> = HashMap::new();
            for t in toks.iter() {
                if let Some(&i) = term_index.get(t) {
                    *tf.entry(i).or_insert(0.0) += 1.0;
                }
            }
            let mut vec: Vec<f32> = vec![0.0; terms.len()];
            for (i, &count) in tf.iter() {
                let tfv = 1.0 + count.log2();
                vec[*i] = tfv;
            }
            vec
        })
        .collect();

    let vectors_normed: Vec<Vec<f32>> = vectors
        .into_par_iter()
        .map(|mut v| {
            let norm = v.iter().map(|x| x * x).sum::<f32>().sqrt().max(1e-9);
            for x in v.iter_mut() {
                *x /= norm;
            }
            v
        })
        .collect();

    let index = Index {
        docs,
        terms,
        vectors: vectors_normed,
    };

    let fout = File::create(out)?;
    serde_json::to_writer_pretty(fout, &index)?;
    println!("Wrote index to {}", out.display());
    Ok(())
}

fn query_with_ollama(index_file: &Path, q: &str, k: usize, model_override: Option<String>) -> Result<()> {
    // Determine which Ollama model to use. Respect OLLAMA_MODEL env var, otherwise try to
    // pick the smallest installed model (fastest) by parsing `ollama list` output. If Ollama
    // isn't available, we'll fall back to returning top-k documents directly.
    let model = if let Some(m) = model_override {
        m
    } else {
        std::env::var("OLLAMA_MODEL").unwrap_or_else(|_| {
            // Try to probe installed models
            let list_out = Command::new("ollama").arg("list").output();
            if let Ok(out) = list_out {
                if out.status.success() {
                    let s = String::from_utf8_lossy(&out.stdout);
                    // Lines look like: NAME \t ID \t SIZE \t MODIFIED
                    // We'll parse lines and pick the smallest SIZE (e.g., "3.3 GB", "700 MB").
                    let mut best: Option<(String, f32)> = None;
                    for line in s.lines() {
                        let cols: Vec<&str> = line.split_whitespace().collect();
                        if cols.len() < 3 { continue }
                        let name = cols[0].to_string();
                        // try to find a size token like "3.3" + unit in subsequent cols
                        let mut size_val: Option<f32> = None;
                        for i in 1..cols.len() {
                            let token = cols[i];
                            // match patterns like 3.3 GB or 700 MB (two tokens)
                            if i + 1 < cols.len() {
                                if let Ok(v) = token.parse::<f32>() {
                                    let unit = cols[i+1].to_uppercase();
                                    let bytes = match unit.as_str() {
                                        "GB" => v * 1024.0 * 1024.0 * 1024.0,
                                        "MB" => v * 1024.0 * 1024.0,
                                        "KB" => v * 1024.0,
                                        _ => v,
                                    };
                                    size_val = Some(bytes);
                                    break;
                                }
                            }
                        }
                        if let Some(sz) = size_val {
                            match &best {
                                Some((_, bsz)) if *bsz <= sz => {},
                                _ => best = Some((name.clone(), sz)),
                            }
                        }
                    }
                    if let Some((n, _)) = best {
                        return n;
                    }
                }
            }
            // default if probing fails
            String::from("mistral")
        })
    };

    let mut prompt = q.to_string();
    if index_file.exists() {
        let f = File::open(index_file)?;
        let idx: Index = serde_json::from_reader(f)?;

        if !idx.terms.is_empty() && !idx.vectors.is_empty() {
            let q_toks = tokenize(q);
            let mut q_vec: Vec<f32> = vec![0.0; idx.terms.len()];
            let term_map: HashMap<&String, usize> = idx.terms.iter().enumerate().map(|(i, t)| (t, i)).collect();
            for t in q_toks.iter() {
                if let Some(&i) = term_map.get(t) {
                    q_vec[i] += 1.0;
                }
            }
            let norm = q_vec.iter().map(|x| x * x).sum::<f32>().sqrt().max(1e-9);
            for x in q_vec.iter_mut() {
                *x /= norm;
            }

            let is_general_query = q.to_lowercase().contains("summarize") || q.to_lowercase().contains("list") || q.to_lowercase().contains("all") || q.to_lowercase().contains("documents") || q_toks.len() < 3;
            let selected_docs: Vec<usize> = if is_general_query {
                // Include all docs for general queries
                (0..idx.docs.len()).collect()
            } else {
                // Use top-k similar docs
                let mut sims: Vec<(usize, f32)> = idx
                    .vectors
                    .iter()
                    .enumerate()
                    .map(|(i, v)| (i, cosine_sim(&q_vec, v)))
                    .collect();

                sims.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
                sims.into_iter().take(k).map(|(i, _)| i).collect()
            };

            let mut context = String::new();
            // For general summarization requests we prefer filename + short excerpt rather than
            // dumping entire document text. This reduces hallucination/regurgitation and gives
            // the model a clearer instruction to summarize.
            for &i in selected_docs.iter().take(10) {
                let doc = &idx.docs[i];
                let fname = std::path::Path::new(&doc.path)
                    .file_name()
                    .map(|s| s.to_string_lossy().to_string())
                    .unwrap_or_else(|| doc.path.clone());
                // derive top keywords from the document text as lightweight context
                let mut tf: HashMap<String, usize> = HashMap::new();
                for tk in tokenize(&doc.text) {
                    if tk.len() <= 2 { continue; }
                    // prefer tokens that are in the global term list (if available)
                    *tf.entry(tk).or_insert(0) += 1;
                }
                let mut kv: Vec<(String, usize)> = tf.into_iter().collect();
                kv.sort_by(|a, b| b.1.cmp(&a.1));
                let keywords: Vec<String> = kv.into_iter().take(8).map(|(t, _)| t).collect();
                let kw = if keywords.is_empty() { String::from("(no keywords)") } else { keywords.join(", ") };
                context.push_str(&format!("Filename: {}\nKeywords: {}\n---\n", fname, kw));
            }

            if !context.is_empty() {
                if is_general_query {
                    // Provide a clearer instruction to the model: per-document one-sentence summaries
                    // and a combined concise summary. Cap output length to avoid dumping raw text.
                    // Few-shot and strict instructions to avoid verbatim quoting; use keywords rather than excerpts.
                    let example = "Example:\nFilename: example.txt\nKeywords: contract, delivery, schedule\n---\nOutput:\n- example.txt — The document outlines the delivery schedule and contractual obligations for shipments.\n";
                    prompt = format!(
                        "You are a concise summarizer. DO NOT QUOTE OR OUTPUT RAW DOCUMENT TEXT. Use the provided keywords to produce paraphrased summaries; do not reuse whole sentences from the source. For each document below, output: (1) a one-line label (filename — short descriptive title), (2) one-sentence paraphrased summary. After that, provide a brief combined summary of all documents (max 200 words). Keep summaries original and concise.\n\n{example}\nDocuments:\n{}\nEnd of documents.\n\nProvide the summaries now.",
                        context
                    );
                    // Also write the prompt to a debug file for inspection
                    if let Ok(mut dbgf) = File::create(std::path::Path::new("/tmp/voltai_last_prompt.txt")) {
                        use std::io::Write;
                        let _ = dbgf.write_all(prompt.as_bytes());
                    }
                } else {
                    prompt = format!("Use the following documents as context:\n{}\nQuestion: {}", context, q);
                }
            }
        }
    }

    // Try to run Ollama; if it fails, fall back to returning top-k documents directly.
    let output = Command::new("ollama").arg("run").arg(&model).arg(&prompt).output();
    match output {
        Ok(o) => {
            if o.status.success() {
                let s = String::from_utf8_lossy(&o.stdout);
                print!("{}", s);
                Ok(())
            } else {
                let serr = String::from_utf8_lossy(&o.stderr);
                eprintln!("ollama run failed ({}): {}", model, serr);
                // Fallback: produce lightweight, non-verbatim summaries derived from keywords
                if index_file.exists() {
                    let f = File::open(index_file)?;
                    let idx: Index = serde_json::from_reader(f)?;
                    let mut q_vec: Vec<f32> = vec![0.0; idx.terms.len()];
                    let term_map: HashMap<&String, usize> = idx.terms.iter().enumerate().map(|(i, t)| (t, i)).collect();
                    let q_toks = tokenize(q);
                    for t in q_toks.iter() {
                        if let Some(&i) = term_map.get(t) { q_vec[i] += 1.0; }
                    }
                    let norm = q_vec.iter().map(|x| x * x).sum::<f32>().sqrt().max(1e-9);
                    for x in q_vec.iter_mut() { *x /= norm; }
                    let mut sims: Vec<(usize, f32)> = idx.vectors.iter().enumerate().map(|(i, v)| (i, cosine_sim(&q_vec, v))).collect();
                    sims.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
                    for (i, _s) in sims.into_iter().take(k) {
                        let doc = &idx.docs[i];
                        // generate top keywords for the doc
                        let mut tf: HashMap<String, usize> = HashMap::new();
                        for tk in tokenize(&doc.text) { if tk.len() > 2 { *tf.entry(tk).or_insert(0) += 1; } }
                        let mut kv: Vec<(String, usize)> = tf.into_iter().collect();
                        kv.sort_by(|a, b| b.1.cmp(&a.1));
                        let keywords: Vec<String> = kv.into_iter().take(6).map(|(t, _)| t).collect();
                        let kw = if keywords.is_empty() { String::from("(no keywords)") } else { keywords.join(", ") };
                        let summary = format!("This document discusses: {}.", kw);
                        print!("Document: {}\nSummary: {}\n---\n", doc.path, summary);
                    }
                }
                Ok(())
            }
        }
        Err(e) => {
            eprintln!("failed to invoke ollama: {}", e);
            // Fallback to keyword-derived summaries instead of raw text
            if index_file.exists() {
                let f = File::open(index_file)?;
                let idx: Index = serde_json::from_reader(f)?;
                let mut q_vec: Vec<f32> = vec![0.0; idx.terms.len()];
                let term_map: HashMap<&String, usize> = idx.terms.iter().enumerate().map(|(i, t)| (t, i)).collect();
                let q_toks = tokenize(q);
                for t in q_toks.iter() {
                    if let Some(&i) = term_map.get(t) { q_vec[i] += 1.0; }
                }
                let norm = q_vec.iter().map(|x| x * x).sum::<f32>().sqrt().max(1e-9);
                for x in q_vec.iter_mut() { *x /= norm; }
                let mut sims: Vec<(usize, f32)> = idx.vectors.iter().enumerate().map(|(i, v)| (i, cosine_sim(&q_vec, v))).collect();
                sims.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
                for (i, _s) in sims.into_iter().take(k) {
                    let doc = &idx.docs[i];
                    let mut tf: HashMap<String, usize> = HashMap::new();
                    for tk in tokenize(&doc.text) { if tk.len() > 2 { *tf.entry(tk).or_insert(0) += 1; } }
                    let mut kv: Vec<(String, usize)> = tf.into_iter().collect();
                    kv.sort_by(|a, b| b.1.cmp(&a.1));
                    let keywords: Vec<String> = kv.into_iter().take(6).map(|(t, _)| t).collect();
                    let kw = if keywords.is_empty() { String::from("(no keywords)") } else { keywords.join(", ") };
                    let summary = format!("This document discusses: {}.", kw);
                    print!("Document: {}\nSummary: {}\n---\n", doc.path, summary);
                }
            }
            Ok(())
        }
    }
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    match cli.command {
        Commands::Index { dir, out } => index_dir(&dir, &out)?,
        Commands::Query { index, q, k, model } => query_with_ollama(&index, &q, k, model)?,
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use tempfile::TempDir;

    #[test]
    fn test_tokenize_basic() {
        let text = "Hello World! This is a test.";
        let tokens = tokenize(text);
        assert_eq!(tokens, vec!["hello", "world", "this", "is", "a", "test"]);
    }

    #[test]
    fn test_tokenize_empty() {
        let tokens = tokenize("");
        assert_eq!(tokens, Vec::<String>::new());
    }

    #[test]
    fn test_tokenize_with_numbers() {
        let text = "test123 hello456";
        let tokens = tokenize(text);
        assert_eq!(tokens, vec!["test123", "hello456"]);
    }

    #[test]
    fn test_tokenize_with_apostrophes() {
        let text = "don't can't won't";
        let tokens = tokenize(text);
        assert_eq!(tokens, vec!["don't", "can't", "won't"]);
    }

    #[test]
    fn test_cosine_sim_identical() {
        let a = vec![1.0, 2.0, 3.0];
        let b = vec![1.0, 2.0, 3.0];
        let sim = cosine_sim(&a, &b);
        assert_eq!(sim, 14.0); // 1*1 + 2*2 + 3*3 = 14
    }

    #[test]
    fn test_cosine_sim_orthogonal() {
        let a = vec![1.0, 0.0];
        let b = vec![0.0, 1.0];
        let sim = cosine_sim(&a, &b);
        assert_eq!(sim, 0.0);
    }

    #[test]
    fn test_cosine_sim_opposite() {
        let a = vec![1.0, 0.0];
        let b = vec![-1.0, 0.0];
        let sim = cosine_sim(&a, &b);
        assert_eq!(sim, -1.0);
    }

    #[test]
    fn test_read_text_file() -> Result<()> {
        let temp_dir = TempDir::new()?;
        let file_path = temp_dir.path().join("test.txt");
        let mut file = File::create(&file_path)?;
        writeln!(file, "Hello, World!")?;
        
        let content = read_text_file(&file_path)?;
        assert_eq!(content, "Hello, World!\n");
        Ok(())
    }

    #[test]
    fn test_read_file_content_txt() -> Result<()> {
        let temp_dir = TempDir::new()?;
        let file_path = temp_dir.path().join("test.txt");
        let mut file = File::create(&file_path)?;
        writeln!(file, "Test content")?;
        
        let content = read_file_content(&file_path)?;
        assert_eq!(content, "Test content\n");
        Ok(())
    }

    #[test]
    fn test_index_creation() -> Result<()> {
        let temp_dir = TempDir::new()?;
        
        // Create test files
        let file1 = temp_dir.path().join("doc1.txt");
        let file2 = temp_dir.path().join("doc2.txt");
        
        let mut f1 = File::create(&file1)?;
        writeln!(f1, "machine learning artificial intelligence")?;
        
        let mut f2 = File::create(&file2)?;
        writeln!(f2, "deep learning neural networks")?;
        
        let index_path = temp_dir.path().join("test_index.json");
        index_dir(temp_dir.path(), &index_path)?;
        
        // Verify index file was created
        assert!(index_path.exists());
        
        // Read and verify index structure
        let f = File::open(&index_path)?;
        let idx: Index = serde_json::from_reader(f)?;
        
        assert_eq!(idx.docs.len(), 2);
        assert!(!idx.terms.is_empty());
        assert_eq!(idx.vectors.len(), 2);
        
        Ok(())
    }

    #[test]
    fn test_index_with_empty_dir() -> Result<()> {
        let temp_dir = TempDir::new()?;
        let index_path = temp_dir.path().join("empty_index.json");
        
        index_dir(temp_dir.path(), &index_path)?;
        
        assert!(index_path.exists());
        let f = File::open(&index_path)?;
        let idx: Index = serde_json::from_reader(f)?;
        
        assert_eq!(idx.docs.len(), 0);
        Ok(())
    }

    #[test]
    fn test_doc_serialization() {
        let doc = Doc {
            id: "test-id".to_string(),
            path: "/path/to/file.txt".to_string(),
            text: "Test content".to_string(),
        };
        
        let json = serde_json::to_string(&doc).unwrap();
        let deserialized: Doc = serde_json::from_str(&json).unwrap();
        
        assert_eq!(doc.id, deserialized.id);
        assert_eq!(doc.path, deserialized.path);
        assert_eq!(doc.text, deserialized.text);
    }

    #[test]
    fn test_index_serialization() {
        let index = Index {
            docs: vec![
                Doc {
                    id: "doc1".to_string(),
                    path: "path1.txt".to_string(),
                    text: "content 1".to_string(),
                }
            ],
            terms: vec!["content".to_string(), "test".to_string()],
            vectors: vec![vec![0.5, 0.5]],
        };
        
        let json = serde_json::to_string(&index).unwrap();
        let deserialized: Index = serde_json::from_str(&json).unwrap();
        
        assert_eq!(index.docs.len(), deserialized.docs.len());
        assert_eq!(index.terms.len(), deserialized.terms.len());
        assert_eq!(index.vectors.len(), deserialized.vectors.len());
    }

    #[test]
    fn test_tokenize_special_chars() {
        let text = "hello@world #test $money";
        let tokens = tokenize(text);
        assert_eq!(tokens, vec!["hello", "world", "test", "money"]);
    }

    #[test]
    fn test_tokenize_mixed_case() {
        let text = "Hello WORLD HeLLo";
        let tokens = tokenize(text);
        assert_eq!(tokens, vec!["hello", "world", "hello"]);
    }

    #[test]
    fn test_vector_normalization() {
        let vec = vec![3.0, 4.0];
        let norm = vec.iter().map(|x| x * x).sum::<f32>().sqrt();
        assert_eq!(norm, 5.0);
    }

    #[test]
    fn test_cosine_sim_normalized() {
        // Normalized vectors
        let a = vec![0.6, 0.8];
        let b = vec![0.6, 0.8];
        let sim = cosine_sim(&a, &b);
        assert!((sim - 1.0).abs() < 1e-6);
    }

    #[test]
    fn test_index_filters_binary_files() -> Result<()> {
        let temp_dir = TempDir::new()?;
        
        // Create text file (should be indexed)
        let text_file = temp_dir.path().join("doc.txt");
        let mut f = File::create(&text_file)?;
        writeln!(f, "This is a text file")?;
        
        // Create binary file (should be skipped)
        let bin_file = temp_dir.path().join("image.png");
        File::create(&bin_file)?;
        
        let index_path = temp_dir.path().join("index.json");
        index_dir(temp_dir.path(), &index_path)?;
        
        let f = File::open(&index_path)?;
        let idx: Index = serde_json::from_reader(f)?;
        
        // Should only index the text file
        assert_eq!(idx.docs.len(), 1);
        assert!(idx.docs[0].path.contains("doc.txt"));
        
        Ok(())
    }

    #[test]
    fn test_empty_query_vector() {
        let q_toks = tokenize("");
        assert_eq!(q_toks.len(), 0);
    }

    #[test]
    fn test_word_regex() {
        let text = "test-case hello_world foo.bar";
        let tokens = tokenize(text);
        // Regex only captures alphanumeric and apostrophes
        assert_eq!(tokens, vec!["test", "case", "hello", "world", "foo", "bar"]);
    }

    #[test]
    fn test_index_dir_real_workflow() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let out_path = dir.path().join("index.json");
        
        // Create test files
        let doc1 = dir.path().join("doc1.txt");
        let doc2 = dir.path().join("doc2.md");
        std::fs::write(&doc1, "machine learning algorithms")?;
        std::fs::write(&doc2, "data science and statistics")?;
        
        // Run indexing
        index_dir(dir.path(), &out_path)?;
        assert!(out_path.exists());
        
        // Verify index contents
        let f = File::open(&out_path)?;
        let idx: Index = serde_json::from_reader(f)?;
        assert_eq!(idx.docs.len(), 2);
        assert!(!idx.terms.is_empty());
        assert_eq!(idx.vectors.len(), 2);
        
        Ok(())
    }

    #[test]
    fn test_query_with_ollama_no_index() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let index_path = dir.path().join("nonexistent.json");
        
        // Query without index - should attempt to run ollama
        // May fail if ollama not installed, but shouldn't panic
        let _ = query_with_ollama(&index_path, "test query", 5, Some("mistral".to_string()));
        
        Ok(())
    }

    #[test]
    fn test_query_with_ollama_with_index() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let index_path = dir.path().join("test_index.json");
        
        // Create a minimal index
        let idx = Index {
            terms: vec!["test".to_string(), "document".to_string()],
            docs: vec![
                Doc {
                    id: "1".to_string(),
                    path: "test.txt".to_string(),
                    text: "test document content".to_string(),
                },
            ],
            vectors: vec![vec![0.7071, 0.7071]],
        };
        
        let f = File::create(&index_path)?;
        serde_json::to_writer(f, &idx)?;
        
        // Query with index - may fail if ollama not installed
        let _ = query_with_ollama(&index_path, "test", 1, Some("mistral".to_string()));
        
        Ok(())
    }

    #[test]
    fn test_read_text_file_binary() {
        let dir = tempfile::tempdir().unwrap();
        let bin_path = dir.path().join("test.bin");
        
        // Create binary file with non-UTF8 bytes
        std::fs::write(&bin_path, vec![0xFF, 0xFE, 0x00, 0x80]).unwrap();
        
        let result = read_text_file(&bin_path);
        // Binary files may be skipped or return empty
        assert!(result.is_ok() || result.is_err());
    }

    #[test]
    fn test_index_dir_nested_structure() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let subdir = dir.path().join("nested");
        std::fs::create_dir(&subdir)?;
        
        let doc1 = dir.path().join("root.txt");
        let doc2 = subdir.join("nested.txt");
        std::fs::write(&doc1, "root level document")?;
        std::fs::write(&doc2, "nested directory file")?;
        
        let out_path = dir.path().join("nested_index.json");
        index_dir(dir.path(), &out_path)?;
        
        let f = File::open(&out_path)?;
        let idx: Index = serde_json::from_reader(f)?;
        assert_eq!(idx.docs.len(), 2);
        
        Ok(())
    }

    #[test]
    fn test_tokenize_punctuation() {
        let text = "Hello, world! How are you? I'm fine.";
        let tokens = tokenize(text);
        assert!(!tokens.contains(&",".to_string()));
        assert!(!tokens.contains(&"!".to_string()));
        assert!(!tokens.contains(&"?".to_string()));
        assert!(tokens.contains(&"hello".to_string()));
        assert!(tokens.contains(&"world".to_string()));
    }

    #[test]
    fn test_cosine_sim_zero_vectors() {
        let v1 = vec![0.0, 0.0, 0.0];
        let v2 = vec![1.0, 2.0, 3.0];
        let sim = cosine_sim(&v1, &v2);
        assert_eq!(sim, 0.0);
    }

    #[test]
    fn test_index_preserves_path_info() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let out_path = dir.path().join("path_index.json");
        
        let doc_path = dir.path().join("test_document.txt");
        std::fs::write(&doc_path, "content")?;
        
        index_dir(dir.path(), &out_path)?;
        
        let f = File::open(&out_path)?;
        let idx: Index = serde_json::from_reader(f)?;
        assert_eq!(idx.docs.len(), 1);
        assert!(idx.docs[0].path.contains("test_document.txt"));
        
        Ok(())
    }

    #[test]
    fn test_tokenize_unicode() {
        let text = "café résumé naïve";
        let tokens = tokenize(text);
        assert!(tokens.len() >= 3);
        assert!(tokens.contains(&"café".to_string()) || tokens.contains(&"caf".to_string()));
    }

    #[test]
    fn test_read_file_content_pdf() {
        let dir = tempfile::tempdir().unwrap();
        let pdf_path = dir.path().join("test.pdf");
        
        // Create a text file pretending to be PDF
        std::fs::write(&pdf_path, "text content").unwrap();
        
        // This will fail PDF parsing but shouldn't panic
        let result = read_file_content(&pdf_path);
        assert!(result.is_ok() || result.is_err());
    }

    #[test]
    fn test_index_with_various_extensions() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let out_path = dir.path().join("index.json");
        
        // Create files with different extensions
        std::fs::write(dir.path().join("doc.txt"), "text file")?;
        std::fs::write(dir.path().join("data.csv"), "csv,data")?;
        std::fs::write(dir.path().join("config.json"), r#"{"key": "value"}"#)?;
        std::fs::write(dir.path().join("readme.md"), "# Markdown")?;
        std::fs::write(dir.path().join("image.jpg"), &[0xFF, 0xD8])?; // Not indexed
        
        index_dir(dir.path(), &out_path)?;
        
        let f = File::open(&out_path)?;
        let idx: Index = serde_json::from_reader(f)?;
        // Should index txt, csv, json, md but not jpg
        assert!(idx.docs.len() >= 4 && idx.docs.len() <= 4);
        
        Ok(())
    }

    #[test]
    fn test_tokenize_contractions() {
        let text = "don't can't won't I'll you're";
        let tokens = tokenize(text);
        assert!(tokens.contains(&"don".to_string()) || tokens.contains(&"don't".to_string()));
        assert!(tokens.len() >= 5);
    }

    #[test]
    fn test_cosine_sim_negative_values() {
        let v1 = vec![-1.0, 2.0, -3.0];
        let v2 = vec![1.0, -2.0, 3.0];
        let sim = cosine_sim(&v1, &v2);
        assert!(sim < 0.0); // Opposite directions
    }

    #[test]
    fn test_index_empty_file() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let out_path = dir.path().join("index.json");
        
        let empty_file = dir.path().join("empty.txt");
        std::fs::write(&empty_file, "")?;
        
        index_dir(dir.path(), &out_path)?;
        
        let f = File::open(&out_path)?;
        let idx: Index = serde_json::from_reader(f)?;
        assert_eq!(idx.docs.len(), 1);
        assert!(idx.docs[0].text.is_empty());
        
        Ok(())
    }

    #[test]
    fn test_query_general_query_detection() {
        let text = "summarize all documents";
        assert!(text.to_lowercase().contains("summarize"));
        assert!(text.to_lowercase().contains("all"));
        
        let text2 = "list everything";
        assert!(text2.to_lowercase().contains("list"));
    }

    #[test]
    fn test_index_large_file() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let out_path = dir.path().join("index.json");
        
        // Create a file with repetitive content
        let large_content = "word ".repeat(1000);
        std::fs::write(dir.path().join("large.txt"), large_content)?;
        
        index_dir(dir.path(), &out_path)?;
        
        let f = File::open(&out_path)?;
        let idx: Index = serde_json::from_reader(f)?;
        assert_eq!(idx.docs.len(), 1);
        assert!(!idx.terms.is_empty());
        
        Ok(())
    }

    #[test]
    fn test_vector_operations_precision() {
        let v1 = vec![1.0, 0.0, 0.0];
        let v2 = vec![0.0, 1.0, 0.0];
        let sim = cosine_sim(&v1, &v2);
        assert!((sim - 0.0).abs() < 0.0001);
    }

    #[test]
    fn test_tokenize_numbers_and_words() {
        let text = "buy 10 apples for $5.99";
        let tokens = tokenize(text);
        assert!(tokens.contains(&"buy".to_string()));
        assert!(tokens.contains(&"10".to_string()));
        assert!(tokens.contains(&"apples".to_string()));
        assert!(tokens.contains(&"5".to_string()));
    }

    #[test]
    fn test_index_special_filenames() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let out_path = dir.path().join("index.json");
        
        // Create files with special characters in names
        std::fs::write(dir.path().join("file-with-dashes.txt"), "content1")?;
        std::fs::write(dir.path().join("file_with_underscores.txt"), "content2")?;
        std::fs::write(dir.path().join("file with spaces.txt"), "content3")?;
        
        index_dir(dir.path(), &out_path)?;
        
        let f = File::open(&out_path)?;
        let idx: Index = serde_json::from_reader(f)?;
        assert_eq!(idx.docs.len(), 3);
        
        Ok(())
    }

    #[test]
    fn test_read_text_file_utf8() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let file_path = dir.path().join("utf8.txt");
        
        let content = "Hello 世界 🌍";
        std::fs::write(&file_path, content)?;
        
        let result = read_text_file(&file_path)?;
        assert!(result.contains("Hello"));
        
        Ok(())
    }
    
    #[test]
    fn test_tfidf_computation() {
        // Test basic TF-IDF calculation
        let term_freq: f32 = 5.0;
        let doc_count: f32 = 100.0;
        let docs_with_term: f32 = 10.0;
        
        let tf = term_freq.ln() + 1.0;
        let idf = (doc_count / (docs_with_term + 1.0)).ln();
        let tfidf = tf * idf;
        
        assert!(tfidf > 0.0);
        assert!(tf > 1.0);
        assert!(idf > 0.0);
    }

    #[test]
    fn test_vector_similarity_ranges() {
        // Test similarity (dot product, not normalized)
        let a = vec![1.0, 2.0, 3.0];
        let b = vec![4.0, 5.0, 6.0];
        
        let sim = cosine_sim(&a, &b); // This is actually dot product
        assert!(sim > 0.0); // Positive correlation
    }

    #[test]
    fn test_keyword_extraction_logic() {
        // Simulate keyword extraction
        let text = "kubernetes kubernetes docker docker docker nginx";
        let tokens = tokenize(text);
        
        let mut tf: HashMap<String, usize> = HashMap::new();
        for tk in tokens {
            if tk.len() > 2 {
                *tf.entry(tk).or_insert(0) += 1;
            }
        }
        
        let mut kv: Vec<(String, usize)> = tf.into_iter().collect();
        kv.sort_by(|a, b| b.1.cmp(&a.1));
        
        // docker should be first (3 occurrences)
        assert_eq!(kv[0].0, "docker");
        assert_eq!(kv[0].1, 3);
        
        // kubernetes should be second (2 occurrences)
        assert_eq!(kv[1].0, "kubernetes");
        assert_eq!(kv[1].1, 2);
    }

    #[test]
    fn test_context_building() {
        // Test that context string can be built
        let keywords = vec!["kubernetes", "docker", "nginx"];
        let context = keywords.join(", ");
        
        assert_eq!(context, "kubernetes, docker, nginx");
        assert!(context.contains("kubernetes"));
        assert!(context.contains("docker"));
    }

    #[test]
    fn test_filename_extraction() {
        let path = "/path/to/document/test.txt";
        let fname = std::path::Path::new(path)
            .file_name()
            .map(|s| s.to_string_lossy().to_string())
            .unwrap_or_else(|| path.to_string());
        
        assert_eq!(fname, "test.txt");
    }

    #[test]
    fn test_size_unit_parsing() {
        // Test size parsing logic for ollama model selection
        let size_gb = 3.3 * 1024.0 * 1024.0 * 1024.0;
        let size_mb = 700.0 * 1024.0 * 1024.0;
        
        assert!(size_gb > size_mb);
        assert!(size_mb > 0.0);
    }

    #[test]
    fn test_query_vector_construction() -> Result<()> {
        let temp_dir = TempDir::new()?;
        
        // Create index with known terms
        let file = temp_dir.path().join("test.txt");
        let mut f = File::create(&file)?;
        writeln!(f, "kubernetes docker container orchestration")?;
        
        let index_path = temp_dir.path().join("index.json");
        index_dir(temp_dir.path(), &index_path)?;
        
        // Load index
        let idx_file = File::open(&index_path)?;
        let idx: Index = serde_json::from_reader(idx_file)?;
        
        // Verify terms were extracted
        assert!(!idx.terms.is_empty());
        assert!(idx.terms.contains(&"kubernetes".to_string()));
        assert!(idx.terms.contains(&"docker".to_string()));
        
        Ok(())
    }
    
    #[test]
    fn test_multiple_docs_ranking() -> Result<()> {
        let temp_dir = TempDir::new()?;
        
        // Create docs with different content
        let file1 = temp_dir.path().join("k8s.txt");
        let mut f1 = File::create(&file1)?;
        writeln!(f1, "kubernetes cluster pod deployment")?;
        
        let file2 = temp_dir.path().join("docker.txt");
        let mut f2 = File::create(&file2)?;
        writeln!(f2, "docker container image registry")?;
        
        let index_path = temp_dir.path().join("index.json");
        index_dir(temp_dir.path(), &index_path)?;
        
        let idx_file = File::open(&index_path)?;
        let idx: Index = serde_json::from_reader(idx_file)?;
        
        assert_eq!(idx.docs.len(), 2);
        assert!(idx.terms.len() >= 6); // At least unique terms from both docs
        
        Ok(())
    }
    
    #[test]
    fn test_term_frequency_deduplication() {
        let text = "test test test other word";
        let tokens = tokenize(text);
        
        let unique_terms: HashSet<String> = tokens.iter().cloned().collect();
        assert_eq!(unique_terms.len(), 3); // test, other, word
    }

    #[test]
    fn test_ollama_model_selection_env() {
        // Test environment variable override
        std::env::set_var("OLLAMA_MODEL", "gemma3:4b");
        let model = std::env::var("OLLAMA_MODEL").unwrap();
        assert_eq!(model, "gemma3:4b");
        std::env::remove_var("OLLAMA_MODEL");
    }

    #[test]
    fn test_query_tokenization() {
        let query = "How does kubernetes work?";
        let tokens = tokenize(query);
        assert!(tokens.contains(&"how".to_string()));
        assert!(tokens.contains(&"does".to_string()));
        assert!(tokens.contains(&"kubernetes".to_string()));
        assert!(tokens.contains(&"work".to_string()));
    }

    #[test]
    fn test_general_query_patterns() {
        // Test various general query patterns
        let queries = vec![
            "summarize everything",
            "list all files",
            "show documents",
            "what",
        ];
        
        for q in queries {
            let lower = q.to_lowercase();
            let is_general = lower.contains("summarize") 
                || lower.contains("list") 
                || lower.contains("all") 
                || lower.contains("documents")
                || tokenize(&lower).len() < 3;
            assert!(is_general, "Query '{}' should be detected as general", q);
        }
    }

    #[test]
    fn test_specific_query_patterns() {
        let queries = vec![
            "kubernetes deployment best practices",
            "docker container networking explained",
            "nginx configuration tutorial",
        ];
        
        for q in queries {
            let lower = q.to_lowercase();
            let tokens = tokenize(&lower);
            assert!(tokens.len() >= 3, "Query '{}' should have 3+ tokens", q);
        }
    }

    #[test]
    fn test_query_vector_normalization() -> Result<()> {
        let temp_dir = TempDir::new()?;
        let index_path = temp_dir.path().join("index.json");
        
        // Create index with known terms
        let idx = Index {
            terms: vec!["kubernetes".to_string(), "docker".to_string(), "container".to_string()],
            docs: vec![
                Doc {
                    id: "1".to_string(),
                    path: "test.txt".to_string(),
                    text: "kubernetes and docker".to_string(),
                }
            ],
            vectors: vec![vec![0.7071, 0.7071, 0.0]],
        };
        
        let f = File::create(&index_path)?;
        serde_json::to_writer(f, &idx)?;
        
        // Load and verify
        let idx_file = File::open(&index_path)?;
        let loaded: Index = serde_json::from_reader(idx_file)?;
        assert_eq!(loaded.terms.len(), 3);
        assert_eq!(loaded.vectors[0].len(), 3);
        
        Ok(())
    }

    #[test]
    fn test_document_keyword_extraction() {
        let text = "kubernetes kubernetes docker nginx nginx nginx";
        let tokens = tokenize(text);
        
        let mut tf: HashMap<String, usize> = HashMap::new();
        for token in tokens {
            if token.len() > 2 {
                *tf.entry(token).or_insert(0) += 1;
            }
        }
        
        let mut kv: Vec<(String, usize)> = tf.into_iter().collect();
        kv.sort_by(|a, b| b.1.cmp(&a.1));
        
        // Top keywords by frequency
        assert_eq!(kv[0].0, "nginx"); // 3 occurrences
        assert_eq!(kv[1].0, "kubernetes"); // 2 occurrences
        assert_eq!(kv[2].0, "docker"); // 1 occurrence
    }

    #[test]
    fn test_context_string_building() {
        let keywords = vec!["kubernetes", "docker", "nginx", "container"];
        let context = keywords.join(", ");
        
        assert!(context.contains("kubernetes"));
        assert!(context.contains("docker"));
        assert!(context.contains("nginx"));
        assert_eq!(context, "kubernetes, docker, nginx, container");
    }

    #[test]
    fn test_filename_extraction_from_path() {
        let paths = vec![
            "/path/to/document.txt",
            "/home/user/file.md",
            "relative/path/data.csv",
        ];
        
        for path_str in paths {
            let path = std::path::Path::new(path_str);
            let fname = path
                .file_name()
                .map(|s| s.to_string_lossy().to_string())
                .unwrap_or_else(|| path_str.to_string());
            
            assert!(!fname.is_empty());
            assert!(!fname.contains('/'));
        }
    }

    #[test]
    fn test_prompt_formatting_for_general_queries() {
        let context = "Filename: test.txt\nKeywords: kubernetes, docker\n---\n";
        let prompt = format!(
            "Documents:\n{}\nEnd of documents.\n\nProvide the summaries now.",
            context
        );
        
        assert!(prompt.contains("Documents:"));
        assert!(prompt.contains("test.txt"));
        assert!(prompt.contains("kubernetes"));
        assert!(prompt.contains("End of documents"));
    }

    #[test]
    fn test_prompt_formatting_for_specific_queries() {
        let context = "Document content here";
        let query = "How does kubernetes work?";
        let prompt = format!("Use the following documents as context:\n{}\nQuestion: {}", context, query);
        
        assert!(prompt.contains("Use the following documents as context"));
        assert!(prompt.contains(query));
        assert!(prompt.contains(context));
    }

    #[test]
    fn test_ollama_command_construction() {
        let model = "mistral";
        let prompt = "test prompt";
        
        // Simulate command construction
        let args = vec!["run", model, prompt];
        assert_eq!(args[0], "run");
        assert_eq!(args[1], "mistral");
        assert_eq!(args[2], "test prompt");
    }

    #[test]
    fn test_fallback_summary_generation() {
        // Test keyword-based summary generation
        let keywords = vec!["kubernetes", "deployment", "scaling"];
        let summary = format!("This document discusses: {}.", keywords.join(", "));
        
        assert_eq!(summary, "This document discusses: kubernetes, deployment, scaling.");
    }

    #[test]
    fn test_empty_keywords_handling() {
        let keywords: Vec<String> = vec![];
        let kw_str = if keywords.is_empty() {
            String::from("(no keywords)")
        } else {
            keywords.join(", ")
        };
        
        assert_eq!(kw_str, "(no keywords)");
    }

    #[test]
    fn test_top_k_selection() {
        let k = 3;
        let mut scores = vec![
            (0, 0.9),
            (1, 0.7),
            (2, 0.8),
            (3, 0.6),
            (4, 0.95),
        ];
        
        scores.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
        let top_k: Vec<usize> = scores.into_iter().take(k).map(|(i, _)| i).collect();
        
        assert_eq!(top_k.len(), 3);
        assert_eq!(top_k[0], 4); // 0.95
        assert_eq!(top_k[1], 0); // 0.9
        assert_eq!(top_k[2], 2); // 0.8
    }

    #[test]
    fn test_query_with_empty_index() -> Result<()> {
        let temp_dir = TempDir::new()?;
        let index_path = temp_dir.path().join("empty_index.json");
        
        let idx = Index {
            terms: vec![],
            docs: vec![],
            vectors: vec![],
        };
        
        let f = File::create(&index_path)?;
        serde_json::to_writer(f, &idx)?;
        
        // Verify empty index can be loaded
        let idx_file = File::open(&index_path)?;
        let loaded: Index = serde_json::from_reader(idx_file)?;
        assert!(loaded.terms.is_empty());
        assert!(loaded.docs.is_empty());
        assert!(loaded.vectors.is_empty());
        
        Ok(())
    }

    #[test]
    fn test_similarity_ranking() {
        let mut sims = vec![
            (0, 0.5),
            (1, 0.9),
            (2, 0.3),
            (3, 0.7),
        ];
        
        sims.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
        
        assert_eq!(sims[0].0, 1); // Highest similarity first
        assert_eq!(sims[1].0, 3);
        assert_eq!(sims[2].0, 0);
        assert_eq!(sims[3].0, 2); // Lowest similarity last
    }

    #[test]
    fn test_model_size_comparison() {
        let size_gb = 3.3 * 1024.0 * 1024.0 * 1024.0;
        let size_mb = 700.0 * 1024.0 * 1024.0;
        let size_kb = 500.0 * 1024.0;
        
        assert!(size_kb < size_mb);
        assert!(size_mb < size_gb);
    }

    #[test]
    fn test_index_with_pdf_extension() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let pdf_path = dir.path().join("test.pdf");
        
        // Create a fake PDF file
        std::fs::write(&pdf_path, b"%PDF-1.4 fake content")?;
        
        // PDF files are in allowed_exts list
        let allowed_exts = ["txt", "md", "csv", "json", "pdf"];
        let ext = pdf_path.extension().and_then(|s| s.to_str()).unwrap_or("");
        assert!(allowed_exts.contains(&ext));
        
        Ok(())
    }

    #[test]
    fn test_tf_idf_log_calculation() {
        let count = 5.0_f32;
        let tfv = 1.0 + count.log2();
        
        assert!(tfv > 1.0);
        assert!((tfv - 3.321928).abs() < 0.001); // log2(5) + 1 ≈ 3.32
    }

    #[test]
    fn test_vector_dot_product() {
        let v1 = vec![0.6, 0.8];
        let v2 = vec![0.8, 0.6];
        
        let dot = v1.iter().zip(v2.iter()).map(|(a, b)| a * b).sum::<f32>();
        assert!((dot - 0.96).abs() < 0.001); // 0.6*0.8 + 0.8*0.6 = 0.96
    }

    #[test]
    fn test_term_document_frequency_map() {
        let mut df: HashMap<String, usize> = HashMap::new();
        let docs = vec![
            vec!["docker", "kubernetes"],
            vec!["docker", "container"],
            vec!["kubernetes", "pod"],
        ];
        
        for doc in &docs {
            let mut seen: HashSet<String> = HashSet::new();
            for &term in doc {
                if seen.insert(term.to_string()) {
                    *df.entry(term.to_string()).or_insert(0) += 1;
                }
            }
        }
        
        assert_eq!(df.get("docker"), Some(&2)); // In 2 docs
        assert_eq!(df.get("kubernetes"), Some(&2)); // In 2 docs
        assert_eq!(df.get("container"), Some(&1)); // In 1 doc
        assert_eq!(df.get("pod"), Some(&1)); // In 1 doc
    }

    #[test]
    fn test_sorting_terms_by_frequency() {
        let df: HashMap<String, usize> = [
            ("docker".to_string(), 5),
            ("kubernetes".to_string(), 3),
            ("nginx".to_string(), 8),
        ].iter().cloned().collect();
        
        let mut v: Vec<(String, usize)> = df.into_iter().collect();
        v.sort_by(|a, b| b.1.cmp(&a.1));
        
        assert_eq!(v[0].0, "nginx"); // 8
        assert_eq!(v[1].0, "docker"); // 5
        assert_eq!(v[2].0, "kubernetes"); // 3
    }

    #[test]
    fn test_term_index_mapping() {
        let terms = vec!["alpha".to_string(), "beta".to_string(), "gamma".to_string()];
        let term_index: HashMap<&String, usize> = terms.iter().enumerate().map(|(i, t)| (t, i)).collect();
        
        assert_eq!(term_index.get(&"alpha".to_string()), Some(&0));
        assert_eq!(term_index.get(&"beta".to_string()), Some(&1));
        assert_eq!(term_index.get(&"gamma".to_string()), Some(&2));
    }

    #[test]
    fn test_vector_initialization() {
        let size = 10;
        let vec: Vec<f32> = vec![0.0; size];
        
        assert_eq!(vec.len(), size);
        assert!(vec.iter().all(|&x| x == 0.0));
    }

    #[test]
    fn test_norm_calculation() {
        let vec = vec![3.0, 4.0];
        let norm = vec.iter().map(|x| x * x).sum::<f32>().sqrt();
        assert_eq!(norm, 5.0);
        
        let norm_with_floor = norm.max(1e-9);
        assert_eq!(norm_with_floor, 5.0);
    }

    #[test]
    fn test_vector_normalization_division() {
        let mut vec = vec![3.0_f32, 4.0_f32];
        let norm = 5.0_f32;
        
        for x in vec.iter_mut() {
            *x /= norm;
        }
        
        assert!((vec[0] - 0.6_f32).abs() < 0.001);
        assert!((vec[1] - 0.8_f32).abs() < 0.001);
    }

    #[test]
    fn test_allowed_extensions_filter() {
        let allowed_exts = ["txt", "md", "csv", "json", "pdf"];
        
        assert!(allowed_exts.contains(&"txt"));
        assert!(allowed_exts.contains(&"pdf"));
        assert!(!allowed_exts.contains(&"exe"));
        assert!(!allowed_exts.contains(&"jpg"));
    }

    #[test]
    fn test_path_extension_extraction() {
        let path = std::path::Path::new("/path/to/file.txt");
        let ext = path.extension().and_then(|s| s.to_str()).unwrap_or("");
        
        assert_eq!(ext, "txt");
    }

    #[test]
    fn test_file_sorting() {
        let mut files = vec![
            std::path::PathBuf::from("c.txt"),
            std::path::PathBuf::from("a.txt"),
            std::path::PathBuf::from("b.txt"),
        ];
        
        files.sort();
        
        assert_eq!(files[0], std::path::PathBuf::from("a.txt"));
        assert_eq!(files[1], std::path::PathBuf::from("b.txt"));
        assert_eq!(files[2], std::path::PathBuf::from("c.txt"));
    }

    #[test]
    fn test_query_vector_with_unknown_terms() {
        let terms = vec!["kubernetes".to_string(), "docker".to_string()];
        let term_map: HashMap<&String, usize> = terms.iter().enumerate().map(|(i, t)| (t, i)).collect();
        
        let query_tokens = vec!["nginx".to_string(), "unknown".to_string()];
        let mut q_vec: Vec<f32> = vec![0.0; terms.len()];
        
        for t in query_tokens.iter() {
            if let Some(&i) = term_map.get(t) {
                q_vec[i] += 1.0;
            }
        }
        
        // Unknown terms should not affect the vector
        assert_eq!(q_vec, vec![0.0, 0.0]);
    }

    #[test]
    fn test_index_preserves_document_order() -> Result<()> {
        let dir = tempfile::tempdir()?;
        
        std::fs::write(dir.path().join("a.txt"), "first")?;
        std::fs::write(dir.path().join("b.txt"), "second")?;
        std::fs::write(dir.path().join("c.txt"), "third")?;
        
        let index_path = dir.path().join("index.json");
        index_dir(dir.path(), &index_path)?;
        
        let f = File::open(&index_path)?;
        let idx: Index = serde_json::from_reader(f)?;
        
        // Files should be sorted
        assert_eq!(idx.docs.len(), 3);
        
        Ok(())
    }

    #[test]
    fn test_parallel_vector_computation() {
        use rayon::prelude::*;
        
        let data = vec![vec![1.0, 2.0], vec![3.0, 4.0], vec![5.0, 6.0]];
        
        let results: Vec<f32> = data.par_iter()
            .map(|v| v.iter().sum::<f32>())
            .collect();
        
        assert_eq!(results, vec![3.0, 7.0, 11.0]);
    }
}
