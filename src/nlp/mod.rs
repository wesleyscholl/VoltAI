// NLP module for BoltAI
pub mod ner;
pub mod sentiment;
pub mod summarization;

pub use ner::extract_entities;
pub use sentiment::analyze_sentiment;
pub use summarization::summarize_text;
