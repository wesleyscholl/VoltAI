// Named Entity Recognition module using pattern-based approach
// This is a lightweight implementation that uses regex patterns to identify entities.
// For production use, consider integrating rust-bert when libtorch is available.
use anyhow::{anyhow, Result};
use regex::Regex;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs::File;
use std::io::Read;
use std::path::Path;
use once_cell::sync::Lazy;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Entity {
    pub word: String,
    pub label: String,
    pub score: f32,
    pub start: usize,
    pub end: usize,
}

// Regex patterns for common entity types
static PERSON_PATTERN: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"\b([A-Z][a-z]+(?:\s+[A-Z][a-z]+)+)\b").unwrap()
});

static ORGANIZATION_PATTERN: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"\b([A-Z][a-z]+(?:\s+(?:Inc|LLC|Corp|Corporation|Ltd|Limited|Company|Co|Group|Institute|University|College)\.?))\b").unwrap()
});

static LOCATION_PATTERN: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"\b((?:United States|USA|UK|United Kingdom|New York|California|Texas|London|Paris|Tokyo|Beijing|Washington|Chicago|Los Angeles|San Francisco|Boston|Seattle|Miami|Austin|Denver|Portland|Atlanta))\b").unwrap()
});

static EMAIL_PATTERN: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"\b([a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,})\b").unwrap()
});

static DATE_PATTERN: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"\b(\d{1,2}[/-]\d{1,2}[/-]\d{2,4}|\d{4}[/-]\d{1,2}[/-]\d{1,2}|(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\s+\d{1,2},?\s+\d{4})\b").unwrap()
});

static MONEY_PATTERN: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"\$\s*\d+(?:,\d{3})*(?:\.\d{2})?|\d+(?:,\d{3})*(?:\.\d{2})?\s*(?:USD|EUR|GBP|dollars?|euros?|pounds?)").unwrap()
});

pub fn extract_entities(file_path: &Path) -> Result<Vec<Entity>> {
    let text = read_file(file_path)?;
    extract_entities_from_text(&text)
}

pub fn extract_entities_from_text(text: &str) -> Result<Vec<Entity>> {
    let mut entities = Vec::new();
    
    // Track seen entities to avoid duplicates
    let mut seen: HashMap<String, bool> = HashMap::new();
    
    // Extract emails
    for cap in EMAIL_PATTERN.captures_iter(text) {
        if let Some(m) = cap.get(1) {
            let word = m.as_str().to_string();
            if !seen.contains_key(&word) {
                seen.insert(word.clone(), true);
                entities.push(Entity {
                    word,
                    label: "EMAIL".to_string(),
                    score: 0.95,
                    start: m.start(),
                    end: m.end(),
                });
            }
        }
    }
    
    // Extract dates
    for cap in DATE_PATTERN.captures_iter(text) {
        if let Some(m) = cap.get(0) {
            let word = m.as_str().to_string();
            if !seen.contains_key(&word) {
                seen.insert(word.clone(), true);
                entities.push(Entity {
                    word,
                    label: "DATE".to_string(),
                    score: 0.90,
                    start: m.start(),
                    end: m.end(),
                });
            }
        }
    }
    
    // Extract money
    for cap in MONEY_PATTERN.captures_iter(text) {
        if let Some(m) = cap.get(0) {
            let word = m.as_str().to_string();
            if !seen.contains_key(&word) {
                seen.insert(word.clone(), true);
                entities.push(Entity {
                    word,
                    label: "MONEY".to_string(),
                    score: 0.90,
                    start: m.start(),
                    end: m.end(),
                });
            }
        }
    }
    
    // Extract locations
    for cap in LOCATION_PATTERN.captures_iter(text) {
        if let Some(m) = cap.get(1) {
            let word = m.as_str().to_string();
            if !seen.contains_key(&word) {
                seen.insert(word.clone(), true);
                entities.push(Entity {
                    word,
                    label: "LOCATION".to_string(),
                    score: 0.85,
                    start: m.start(),
                    end: m.end(),
                });
            }
        }
    }
    
    // Extract organizations
    for cap in ORGANIZATION_PATTERN.captures_iter(text) {
        if let Some(m) = cap.get(1) {
            let word = m.as_str().to_string();
            if !seen.contains_key(&word) {
                seen.insert(word.clone(), true);
                entities.push(Entity {
                    word,
                    label: "ORGANIZATION".to_string(),
                    score: 0.80,
                    start: m.start(),
                    end: m.end(),
                });
            }
        }
    }
    
    // Extract person names (after organizations to avoid false positives)
    for cap in PERSON_PATTERN.captures_iter(text) {
        if let Some(m) = cap.get(1) {
            let word = m.as_str().to_string();
            // Filter out likely organizations and other false positives
            if !word.contains("Inc") && !word.contains("Corp") && 
               !word.contains("LLC") && !word.contains("Ltd") &&
               !word.contains("University") && !word.contains("College") &&
               !seen.contains_key(&word) {
                seen.insert(word.clone(), true);
                entities.push(Entity {
                    word,
                    label: "PERSON".to_string(),
                    score: 0.75,
                    start: m.start(),
                    end: m.end(),
                });
            }
        }
    }
    
    // Sort by position in text
    entities.sort_by_key(|e| e.start);
    
    Ok(entities)
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
    fn test_extract_entities_from_text() {
        let text = "Barack Obama was born in Hawaii. He worked in Chicago and later became the 44th President of the United States.";
        let result = extract_entities_from_text(text);
        assert!(result.is_ok());
        let entities = result.unwrap();
        // Should find entities
        assert!(!entities.is_empty());
        // Should find locations
        assert!(entities.iter().any(|e| e.label == "LOCATION"));
    }

    #[test]
    fn test_extract_email() {
        let text = "Contact us at support@example.com for more information.";
        let result = extract_entities_from_text(text);
        assert!(result.is_ok());
        let entities = result.unwrap();
        assert!(entities.iter().any(|e| e.label == "EMAIL"));
    }

    #[test]
    fn test_extract_date() {
        let text = "The meeting is scheduled for Jan 15, 2024.";
        let result = extract_entities_from_text(text);
        assert!(result.is_ok());
        let entities = result.unwrap();
        assert!(entities.iter().any(|e| e.label == "DATE"));
    }
}
