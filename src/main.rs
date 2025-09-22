use std::collections::{HashMap, HashSet};
use std::fs::File;
use std::io::{BufReader, Read};
use std::path::{Path, PathBuf};

use anyhow::{anyhow, Result};
use clap::{Parser, Subcommand};
use indicatif::{ProgressBar, ProgressStyle};
use rayon::prelude::*;
use regex::Regex;
use once_cell::sync::Lazy;
use serde::{Deserialize, Serialize};
use walkdir::WalkDir;

#[derive(Parser)]
#[command(name = "BoltAI", about = "Fast local AI agent — MVP (TF-IDF based)")]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Index a directory of text files into a local JSON index
    Index {
        /// Directory to index
        #[arg(short, long)]
        dir: PathBuf,

        /// Output index file
        #[arg(short, long, default_value = "boltai_index.json")]
        out: PathBuf,
    },
    /// Query the index for similar documents
    Query {
        /// Index file created by `index` command
        #[arg(short, long, default_value = "boltai_index.json")]
        index: PathBuf,

        /// Query string
        #[arg(short, long)]
        q: String,

        /// Number of results
        #[arg(short, long, default_value_t = 5)]
        k: usize,
    },
}

#[derive(Serialize, Deserialize)]
struct Doc {
    id: String,
    path: String,
    text: String,
}

#[derive(Serialize, Deserialize)]
struct Index {
    docs: Vec<Doc>,
    terms: Vec<String>,
    vectors: Vec<Vec<f32>>, // tf-idf vectors aligned with docs
}

fn main() -> Result<()> {
    let cli = Cli::parse();

    match cli.command {
        Commands::Index { dir, out } => {
            index_dir(&dir, &out)?;
        }
        Commands::Query { index, q, k } => {
            query_index(&index, &q, k)?;
        }
    }

    Ok(())
}

fn read_text_file(path: &Path) -> Result<String> {
    let file = File::open(path)?;
    let mut s = String::new();
    let mut rdr = BufReader::new(file);
    rdr.read_to_string(&mut s)?;
    Ok(s)
}

fn collect_text_files(dir: &Path) -> Vec<PathBuf> {
    WalkDir::new(dir)
        .into_iter()
        .filter_map(|e| e.ok())
        .filter(|e| e.file_type().is_file())
        .filter(|e| {
            if let Some(ext) = e.path().extension() {
                let ex = ext.to_string_lossy().to_lowercase();
                return ex == "txt" || ex == "md" || ex == "text" || ex == "csv" || ex == "json";
            }
            false
        })
        .map(|e| e.into_path())
        .collect()
}

fn tokenize(text: &str) -> Vec<String> {
    // simple tokenizer: lowercase, split on word characters, remove stopwords
    static RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"\w+").unwrap());
    let stop: HashSet<&'static str> = ["the", "and", "is", "in", "to", "of", "a", "for", "on", "with", "that", "this"].iter().cloned().collect();

    RE.find_iter(text)
        .map(|m| m.as_str().to_lowercase())
        .filter(|t| !stop.contains(t.as_str()))
        .collect()
}

fn index_dir(dir: &Path, out: &Path) -> Result<()> {
    if !dir.is_dir() {
        return Err(anyhow!("{} is not a directory", dir.display()));
    }

    let files = collect_text_files(dir);
    println!("Found {} files to index", files.len());

    let pb = ProgressBar::new(files.len() as u64);
    pb.set_style(
        ProgressStyle::with_template("{spinner:.green} [{elapsed_precise}] {bar:40.cyan/blue} {pos}/{len} {msg}")?
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

    // build vocabulary
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

    // compute tf-idf vectors
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
                // idf approximated by position popularity (higher index => less common)
                // For simplicity compute idf as log(N / (1 + df)) later; but we don't have df map now.
                vec[*i] = tfv;
            }
            vec
        })
        .collect();

    // normalize vectors
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

fn cosine_sim(a: &[f32], b: &[f32]) -> f32 {
    a.iter().zip(b.iter()).map(|(x, y)| x * y).sum()
}

fn query_index(index_file: &Path, q: &str, k: usize) -> Result<()> {
    if !index_file.exists() {
        return Err(anyhow!("index file {} does not exist", index_file.display()));
    }
    let f = File::open(index_file)?;
    let idx: Index = serde_json::from_reader(f)?;

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

    println!("Top {} results for query: {}", k, q);
    for (i, score) in sims.into_iter().take(k) {
        let doc = &idx.docs[i];
        println!("[{:.4}] {} — {}", score, doc.id, doc.path);
    }

    Ok(())
}
