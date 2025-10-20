// Text Summarization module using extractive approach
// This is a lightweight implementation that uses sentence scoring to extract key sentences.
// For production use, consider integrating rust-bert when libtorch is available.
use anyhow::{anyhow, Result};
use regex::Regex;
use std::collections::HashMap;
use std::fs::File;
use std::io::Read;
use std::path::Path;
use once_cell::sync::Lazy;

static SENTENCE_PATTERN: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"[^.!?]+[.!?]+").unwrap()
});

static WORD_PATTERN: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"[a-zA-Z0-9']+").unwrap()
});

// Common stop words to filter out when scoring sentences
static STOP_WORDS: Lazy<std::collections::HashSet<&'static str>> = Lazy::new(|| {
    [
        "a", "an", "and", "are", "as", "at", "be", "by", "for", "from",
        "has", "he", "in", "is", "it", "its", "of", "on", "that", "the",
        "to", "was", "will", "with", "this", "but", "they", "have",
        "had", "what", "when", "where", "who", "which", "why", "how"
    ].iter().copied().collect()
});

pub fn summarize_text(file_path: &Path) -> Result<String> {
    let text = read_file(file_path)?;
    summarize_text_content(&text)
}

pub fn summarize_text_content(text: &str) -> Result<String> {
    // Extract sentences
    let sentences: Vec<&str> = SENTENCE_PATTERN
        .find_iter(text)
        .map(|m| m.as_str().trim())
        .filter(|s| !s.is_empty())
        .collect();
    
    if sentences.is_empty() {
        return Ok("(No content to summarize)".to_string());
    }
    
    // If text is short, return it as is
    if sentences.len() <= 3 {
        return Ok(text.to_string());
    }
    
    // Calculate word frequencies (excluding stop words)
    let mut word_freq: HashMap<String, usize> = HashMap::new();
    for sentence in &sentences {
        for word in WORD_PATTERN.find_iter(sentence) {
            let word_str = word.as_str().to_lowercase();
            if !STOP_WORDS.contains(word_str.as_str()) && word_str.len() > 2 {
                *word_freq.entry(word_str).or_insert(0) += 1;
            }
        }
    }
    
    // Find the maximum frequency
    let max_freq = word_freq.values().max().copied().unwrap_or(1);
    
    // Normalize frequencies
    for freq in word_freq.values_mut() {
        *freq = (*freq * 100) / max_freq;
    }
    
    // Score sentences based on word frequencies
    let mut sentence_scores: Vec<(usize, usize)> = Vec::new();
    for (idx, sentence) in sentences.iter().enumerate() {
        let mut score = 0;
        let words: Vec<_> = WORD_PATTERN.find_iter(sentence).collect();
        
        for word in &words {
            let word_str = word.as_str().to_lowercase();
            if let Some(&freq) = word_freq.get(&word_str) {
                score += freq;
            }
        }
        
        // Normalize by sentence length to avoid bias toward long sentences
        if !words.is_empty() {
            score /= words.len();
        }
        
        // Boost score for sentences at the beginning (often contain key info)
        if idx == 0 {
            score = (score as f32 * 1.5) as usize;
        }
        
        sentence_scores.push((idx, score));
    }
    
    // Sort by score and select top sentences
    sentence_scores.sort_by(|a, b| b.1.cmp(&a.1));
    
    // Select top 30% of sentences (minimum 2, maximum 5)
    let num_summary_sentences = (sentences.len() * 30 / 100).max(2).min(5);
    let mut selected_indices: Vec<usize> = sentence_scores
        .iter()
        .take(num_summary_sentences)
        .map(|(idx, _)| *idx)
        .collect();
    
    // Sort selected sentences by their original order
    selected_indices.sort();
    
    // Build the summary
    let summary: Vec<String> = selected_indices
        .iter()
        .map(|&idx| sentences[idx].to_string())
        .collect();
    
    Ok(summary.join(" "))
}

fn read_file(path: &Path) -> Result<String> {
    let ext = path.extension().and_then(|s| s.to_str()).unwrap_or("");
    
    match ext {
        "txt" | "md" | "csv" | "json" => {
            let mut file = File::open(path)?;
            let mut content = String::new();
            file.read_to_string(&mut content)?;
            Ok(content)
        }
        "pdf" => {
            pdf_extract::extract_text(path)
                .map_err(|e| anyhow!("PDF extraction failed: {}", e))
        }
        _ => Err(anyhow!("Unsupported file format: {}", ext)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_summarize_text_content() {
        let long_text = "Natural language processing is a field of artificial intelligence \
                        that focuses on the interaction between computers and humans through \
                        natural language. The ultimate objective of NLP is to read, decipher, \
                        understand, and make sense of the human languages in a manner that is valuable. \
                        NLP combines computational linguistics with statistical models and machine learning. \
                        Applications include translation, sentiment analysis, and chatbots.";
        let result = summarize_text_content(long_text);
        assert!(result.is_ok());
        let summary = result.unwrap();
        assert!(!summary.is_empty());
        assert!(summary.len() < long_text.len());
    }

    #[test]
    fn test_summarize_short_text() {
        let short_text = "This is a short text.";
        let result = summarize_text_content(short_text);
        assert!(result.is_ok());
        let summary = result.unwrap();
        assert_eq!(summary, short_text);
    }

    #[test]
    fn test_summarize_empty_text() {
        let empty_text = "";
        let result = summarize_text_content(empty_text);
        assert!(result.is_ok());
        let summary = result.unwrap();
        assert_eq!(summary, "(No content to summarize)");
    }
}
