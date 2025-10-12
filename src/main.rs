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
    let allowed_exts = ["txt", "md", "csv", "json"];
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
            let text = read_text_file(p).unwrap_or_else(|_| String::new());
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

fn query_with_ollama(index_file: &Path, q: &str, k: usize) -> Result<()> {
    let model = std::env::var("OLLAMA_MODEL").unwrap_or_else(|_| String::from("mistral"));

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

            let mut sims: Vec<(usize, f32)> = idx
                .vectors
                .iter()
                .enumerate()
                .map(|(i, v)| (i, cosine_sim(&q_vec, v)))
                .collect();

            sims.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));

            let mut context = String::new();
            for (i, _score) in sims.into_iter().take(k) {
                let doc = &idx.docs[i];
                context.push_str(&format!("Document: {}\n{}\n---\n", doc.path, doc.text));
            }

            if !context.is_empty() {
                prompt = format!("Use the following documents as context:\n{}\nQuestion: {}", context, q);
            }
        }
    }

    let output = Command::new("ollama").arg("run").arg(&model).arg(&prompt).output();
    match output {
        Ok(o) => {
            if o.status.success() {
                let s = String::from_utf8_lossy(&o.stdout);
                print!("{}", s);
                Ok(())
            } else {
                let serr = String::from_utf8_lossy(&o.stderr);
                Err(anyhow!("ollama failed: {}", serr))
            }
        }
        Err(e) => Err(anyhow!("failed to invoke ollama: {}", e)),
    }
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    match cli.command {
        Commands::Index { dir, out } => index_dir(&dir, &out)?,
        Commands::Query { index, q, k } => query_with_ollama(&index, &q, k)?,
    }
    Ok(())
}
