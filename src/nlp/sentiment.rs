// Sentiment Analysis module using lexicon-based approach
// This is a lightweight implementation that uses word lists to determine sentiment.
// For production use, consider integrating rust-bert when libtorch is available.
use anyhow::{anyhow, Result};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::fs::File;
use std::io::Read;
use std::path::Path;
use once_cell::sync::Lazy;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Sentiment {
    pub label: String,
    pub score: f32,
}

// Positive words lexicon
static POSITIVE_WORDS: Lazy<HashSet<&'static str>> = Lazy::new(|| {
    [
        "good", "great", "excellent", "wonderful", "fantastic", "amazing", "awesome",
        "love", "happy", "joy", "pleased", "delighted", "satisfied", "perfect",
        "beautiful", "brilliant", "outstanding", "superb", "magnificent", "marvelous",
        "terrific", "fabulous", "exceptional", "impressive", "remarkable", "best",
        "better", "positive", "advantage", "benefit", "success", "successful",
        "win", "winner", "winning", "accomplished", "achievement", "triumph",
        "enjoy", "pleasant", "comfortable", "excited", "exciting", "thrilled",
        "approve", "approved", "approval", "like", "liked", "favorite", "prefer"
    ].iter().copied().collect()
});

// Negative words lexicon
static NEGATIVE_WORDS: Lazy<HashSet<&'static str>> = Lazy::new(|| {
    [
        "bad", "terrible", "awful", "horrible", "poor", "worst", "worse",
        "hate", "angry", "sad", "upset", "disappointed", "dissatisfied", "unhappy",
        "fail", "failure", "failed", "problem", "issue", "wrong", "error",
        "difficult", "hard", "tough", "struggle", "struggling", "broken",
        "pain", "painful", "hurt", "hurting", "damage", "damaged", "disaster",
        "negative", "loss", "lose", "losing", "lost", "defeat", "defeated",
        "reject", "rejected", "rejection", "dislike", "disliked", "unpleasant",
        "uncomfortable", "disappointing", "frustrate", "frustrated", "frustrating"
    ].iter().copied().collect()
});

// Intensifiers
static INTENSIFIERS: Lazy<HashSet<&'static str>> = Lazy::new(|| {
    ["very", "extremely", "absolutely", "really", "incredibly", "highly", "totally"]
        .iter().copied().collect()
});

// Negation words
static NEGATIONS: Lazy<HashSet<&'static str>> = Lazy::new(|| {
    ["not", "no", "never", "nothing", "nobody", "nowhere", "neither", "nor", "none"]
        .iter().copied().collect()
});

pub fn analyze_sentiment(file_path: &Path) -> Result<Vec<Sentiment>> {
    let text = read_file(file_path)?;
    analyze_sentiment_text(&text)
}

pub fn analyze_sentiment_text(text: &str) -> Result<Vec<Sentiment>> {
    let words: Vec<String> = text
        .to_lowercase()
        .split(|c: char| !c.is_alphanumeric() && c != '\'')
        .filter(|s| !s.is_empty())
        .map(String::from)
        .collect();
    
    let mut positive_score = 0.0;
    let mut negative_score = 0.0;
    
    let mut i = 0;
    while i < words.len() {
        let word = &words[i];
        let mut multiplier = 1.0;
        
        // Check for intensifiers in the previous word
        if i > 0 && INTENSIFIERS.contains(words[i - 1].as_str()) {
            multiplier = 1.5;
        }
        
        // Check for negation in previous 1-2 words
        let is_negated = (i > 0 && NEGATIONS.contains(words[i - 1].as_str())) ||
                        (i > 1 && NEGATIONS.contains(words[i - 2].as_str()));
        
        if POSITIVE_WORDS.contains(word.as_str()) {
            if is_negated {
                negative_score += 1.0 * multiplier;
            } else {
                positive_score += 1.0 * multiplier;
            }
        } else if NEGATIVE_WORDS.contains(word.as_str()) {
            if is_negated {
                positive_score += 1.0 * multiplier;
            } else {
                negative_score += 1.0 * multiplier;
            }
        }
        
        i += 1;
    }
    
    // Determine overall sentiment
    let total_score = positive_score + negative_score;
    let sentiment = if total_score == 0.0 {
        Sentiment {
            label: "Neutral".to_string(),
            score: 0.5,
        }
    } else {
        let pos_ratio = positive_score / total_score;
        let neg_ratio = negative_score / total_score;
        
        if pos_ratio > neg_ratio + 0.1 {
            Sentiment {
                label: "Positive".to_string(),
                score: pos_ratio,
            }
        } else if neg_ratio > pos_ratio + 0.1 {
            Sentiment {
                label: "Negative".to_string(),
                score: neg_ratio,
            }
        } else {
            Sentiment {
                label: "Neutral".to_string(),
                score: 0.5,
            }
        }
    };
    
    Ok(vec![sentiment])
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
    fn test_analyze_sentiment_positive() {
        let positive_text = "This is a wonderful day! I'm feeling great and happy!";
        let result = analyze_sentiment_text(positive_text);
        assert!(result.is_ok());
        let sentiments = result.unwrap();
        assert!(!sentiments.is_empty());
        assert_eq!(sentiments[0].label, "Positive");
    }

    #[test]
    fn test_analyze_sentiment_negative() {
        let negative_text = "This is terrible and awful. I hate it!";
        let result = analyze_sentiment_text(negative_text);
        assert!(result.is_ok());
        let sentiments = result.unwrap();
        assert!(!sentiments.is_empty());
        assert_eq!(sentiments[0].label, "Negative");
    }

    #[test]
    fn test_analyze_sentiment_neutral() {
        let neutral_text = "The sky is blue. The grass is green.";
        let result = analyze_sentiment_text(neutral_text);
        assert!(result.is_ok());
        let sentiments = result.unwrap();
        assert!(!sentiments.is_empty());
        assert_eq!(sentiments[0].label, "Neutral");
    }

    #[test]
    fn test_negation_handling() {
        let negated_text = "This is not good at all.";
        let result = analyze_sentiment_text(negated_text);
        assert!(result.is_ok());
        let sentiments = result.unwrap();
        assert_eq!(sentiments[0].label, "Negative");
    }
}
