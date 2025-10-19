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
#[command(name = "BoltAI", about = "Fast local AI agent — MVP (TF-IDF based)")]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    Index {
        #[arg(short, long)]
        dir: PathBuf,
        #[arg(short, long, default_value = "boltai_index.json")]
        out: PathBuf,
    },
    Query {
        #[arg(short, long, default_value = "boltai_index.json")]
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
                    if let Ok(mut dbgf) = File::create(std::path::Path::new("/tmp/boltai_last_prompt.txt")) {
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
