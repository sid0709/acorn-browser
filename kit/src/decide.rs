//! The decision model of the kit: the same OpenRouter chat API the driving model uses, asked for
//! a JSON object of probabilities, one per question. A cheap, quick model does here; the questions
//! are yes or no about a screenshot.

use std::collections::BTreeMap;
use std::time::Instant;

use harness::openrouter::{OpenRouter, UreqTransport};
use harness::ports::{Answer, Decider, Decision, Error, ErrorKind, Message, Model, ModelRequest, Part, QuestionKind, Role, Verdicts};
use serde_json::{Map, Value, json};

/// The name the schema of a decision is sent under.
const SCHEMA_NAME: &str = "decision";

/// A decider over OpenRouter's chat API.
pub struct OpenRouterDecider {
    client: OpenRouter,
    name: String,
}

impl OpenRouterDecider {
    pub fn new(api_key: &str, model: &str, base_url: &str) -> Self {
        OpenRouterDecider { client: OpenRouter::new(api_key, model, base_url, "", Box::new(UreqTransport::default())), name: model.to_string() }
    }
}

impl Decider for OpenRouterDecider {
    fn decide(&self, decision: Decision) -> Result<Verdicts, Error> {
        let mut text = String::from("Answer each question below about the state shown with the probability, from 0 to 1, that the answer is yes. Judge only from what is shown.\n\n");
        let mut properties = Map::new();
        let mut required = Vec::new();
        for (key, question) in &decision.questions {
            if question.kind != QuestionKind::YesNo {
                return Err(Error::new(ErrorKind::BadRequest, "this kit answers yes/no questions only"));
            }
            text.push_str(&format!("Question {key}: {}\n\n", question.instructions.trim()));
            properties.insert(key.clone(), json!({"type": "number"}));
            required.push(Value::String(key.clone()));
        }
        let mut images = Vec::new();
        text.push_str("The state:\n");
        for part in &decision.state {
            match part {
                Part::Text(line) => {
                    text.push_str(line.trim());
                    text.push('\n');
                }
                Part::Image(data_url) => images.push(data_url.clone()),
            }
        }
        let schema = json!({
            "type": "object", "additionalProperties": false, "required": ["answers"],
            "properties": {"answers": {"type": "object", "additionalProperties": false, "required": required, "properties": properties}}
        });
        let messages = vec![
            Message {
                role: Role::System,
                text: "You are a careful checker. You answer only with the JSON object asked for: a probability from 0 to 1 for each question, judged from what is shown, and nothing else.".to_string(),
                ..Default::default()
            },
            Message { role: Role::User, text, images, ..Default::default() },
        ];
        let started = Instant::now();
        let response = self.client.complete(ModelRequest { messages, schema_name: SCHEMA_NAME.to_string(), schema })?;
        let parsed: Value = serde_json::from_str(response.content.trim()).map_err(|e| Error::new(ErrorKind::Other, format!("the checker did not answer with JSON: {e}")))?;
        let mut answers = BTreeMap::new();
        for key in decision.questions.keys() {
            let probability = parsed["answers"][key].as_f64().ok_or_else(|| Error::new(ErrorKind::Other, format!("the checker gave no number for {key:?}")))?;
            answers.insert(key.clone(), Answer { probability: Some(probability.clamp(0.0, 1.0)), ..Default::default() });
        }
        Ok(Verdicts {
            model: if response.model.is_empty() { self.name.clone() } else { response.model },
            answers,
            usage: response.usage,
            latency: if response.latency.is_zero() { started.elapsed() } else { response.latency },
        })
    }

    fn name(&self) -> &str {
        &self.name
    }
}
