//! The decision model of the kit: a Decisions API, which takes a state and typed questions and
//! answers each with a probability. Nothing is generated, so a call is quick and cheap: the thing
//! for yes/no questions about a screenshot. Two providers speak it, in two shapes: OpenRouter's
//! (the default, on the same key as the driving model) and OpenAI's own (on an OpenAI key). The
//! shapes are those acorn-agent's decide package speaks.
//!
//! Every call is metered (`Tally`): how many, the tokens, the cost the provider reported, and the
//! time waited, so a run's price and speed are read from what the providers said, not guessed.

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use harness::openrouter::{Transport, UreqTransport};
use harness::ports::{Answer, Decider, Decision, Error, ErrorKind, Model, ModelRequest, ModelResponse, Part, QuestionKind, Usage, Verdicts};
use harness::recover;
use serde_json::{Map, Value, json};

pub const OPENROUTER_DECISIONS_URL: &str = "https://openrouter.ai/api/alpha/decisions";
pub const OPENROUTER_DECISION_MODEL: &str = "openai/gpt-6-luna-decisions";
pub const OPENAI_DECISIONS_URL: &str = "https://api.openai.com/v1/decisions";
pub const OPENAI_DECISION_MODEL: &str = "gpt-6-luna";
/// The most characters of a provider error kept for the message.
const MAX_ERROR_TEXT: usize = 300;

/// Which provider's shape a client speaks.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Wire {
    OpenRouter,
    OpenAI,
}

/// What one model's calls added up to.
#[derive(Clone, Copy, Debug, Default)]
pub struct Tally {
    pub calls: u32,
    pub usage: Usage,
    pub waited: Duration,
}

impl Tally {
    fn add(&mut self, usage: Usage, waited: Duration) {
        self.calls += 1;
        self.usage.add(usage);
        self.waited += waited;
    }
}

/// A shared counter of calls, for the end of the run.
#[derive(Clone, Default)]
pub struct Meter(Arc<Mutex<Tally>>);

impl Meter {
    pub fn read(&self) -> Tally {
        *self.0.lock().unwrap()
    }
    fn add(&self, usage: Usage, waited: Duration) {
        self.0.lock().unwrap().add(usage, waited);
    }
}

/// A client of a Decisions API.
pub struct Decisions {
    api_key: String,
    model: String,
    url: String,
    wire: Wire,
    transport: Box<dyn Transport + Send + Sync>,
    pub meter: Meter,
}

impl Decisions {
    pub fn new(api_key: &str, model: &str, url: &str, wire: Wire) -> Self {
        Decisions { api_key: api_key.trim().to_string(), model: model.to_string(), url: url.to_string(), wire, transport: Box::new(UreqTransport::default()), meter: Meter::default() }
    }

    fn encode(&self, decision: &Decision) -> Value {
        match self.wire {
            Wire::OpenRouter => {
                let state: Vec<Value> = decision
                    .state
                    .iter()
                    .map(|part| match part {
                        Part::Text(text) => json!({"type": "text", "text": text}),
                        Part::Image(url) => json!({"type": "image_url", "image_url": {"url": url}}),
                    })
                    .collect();
                let mut questions = Map::new();
                for (key, question) in &decision.questions {
                    questions.insert(
                        key.clone(),
                        match question.kind {
                            QuestionKind::YesNo => json!({"type": "noul", "instructions": question.instructions, "criteria": {"true": "yes", "false": "no"}}),
                            QuestionKind::Choice => json!({"type": "choice", "instructions": question.instructions, "criteria": question.options}),
                        },
                    );
                }
                json!({"model": self.model, "state": state, "questions": questions})
            }
            Wire::OpenAI => {
                let content: Vec<Value> = decision
                    .state
                    .iter()
                    .map(|part| match part {
                        Part::Text(text) => json!({"type": "input_text", "text": text}),
                        Part::Image(url) => json!({"type": "input_image", "image_url": url}),
                    })
                    .collect();
                let questions: Vec<Value> = decision
                    .questions
                    .iter()
                    .map(|(key, question)| match question.kind {
                        QuestionKind::YesNo => json!({"type": "predicate", "name": key, "instructions": question.instructions}),
                        QuestionKind::Choice => json!({"type": "choice", "name": key, "instructions": question.instructions,
                            "choices": question.options.iter().map(|(value, description)| json!({"value": value, "description": description})).collect::<Vec<_>>()}),
                    })
                    .collect();
                json!({"model": self.model, "input": [{"role": "user", "content": content}], "questions": questions})
            }
        }
    }

    fn decode(&self, payload: &str) -> Result<Verdicts, Error> {
        let value: Value = serde_json::from_str(payload).map_err(|e| Error::new(ErrorKind::Server, format!("the decision answer is not JSON: {e}")))?;
        let usage = &value["usage"];
        let mut out = Verdicts {
            model: value["model"].as_str().unwrap_or(&self.model).to_string(),
            usage: Usage {
                input_tokens: usage["input_tokens"].as_u64().unwrap_or(0),
                output_tokens: usage["output_tokens"].as_u64().unwrap_or(0),
                cached_tokens: usage["input_tokens_details"]["cached_tokens"].as_u64().unwrap_or(0),
                cost: usage["cost"].as_f64().unwrap_or(0.0),
                ..Default::default()
            },
            ..Default::default()
        };
        let answer_of = |a: &Value| -> Answer {
            let mut answer = Answer { probability: a["noul"].as_f64().or(a["probability"].as_f64()), choice: a["choice"].as_str().map(str::to_string), ..Default::default() };
            if let Some(weights) = a["probabilities"].as_object() {
                answer.probabilities = weights.iter().filter_map(|(k, v)| v.as_f64().map(|p| (k.clone(), p))).collect();
            } else if let Some(weights) = a["probabilities"].as_array() {
                answer.probabilities = weights.iter().filter_map(|w| Some((w["value"].as_str()?.to_string(), w["probability"].as_f64()?))).collect();
            }
            answer
        };
        match self.wire {
            Wire::OpenRouter => {
                let answers = value["answers"].as_object().ok_or_else(|| Error::new(ErrorKind::Server, "the decision answer has no answers"))?;
                out.answers = answers.iter().map(|(k, a)| (k.clone(), answer_of(a))).collect();
            }
            Wire::OpenAI => {
                let answers = value["answers"].as_array().ok_or_else(|| Error::new(ErrorKind::Server, "the decision answer has no answers"))?;
                // A question the model declined ("refusal") is left unanswered.
                out.answers = answers.iter().filter(|a| a["type"] != "refusal").filter_map(|a| Some((a["name"].as_str()?.to_string(), answer_of(a)))).collect();
            }
        }
        Ok(out)
    }
}

/// Reads a provider's error off a failed status, with the kind that says whether to retry.
fn status_error(status: u16, payload: &str) -> Error {
    let message = serde_json::from_str::<Value>(payload).ok().and_then(|v| v["error"]["message"].as_str().map(str::to_string)).unwrap_or_default();
    let message: String = message.chars().take(MAX_ERROR_TEXT).collect();
    let kind = match status {
        429 => ErrorKind::RateLimited,
        500..=599 => ErrorKind::Server,
        _ => ErrorKind::BadRequest,
    };
    Error::new(kind, format!("the decision model answered {status}: {message}"))
}

impl Decider for Decisions {
    fn decide(&self, decision: Decision) -> Result<Verdicts, Error> {
        if self.api_key.is_empty() {
            return Err(Error::new(ErrorKind::BadRequest, "no API key for the decision model"));
        }
        let body = serde_json::to_vec(&self.encode(&decision)).map_err(|e| Error::new(ErrorKind::BadRequest, e.to_string()))?;
        let bearer = format!("Bearer {}", self.api_key);
        let started = Instant::now();
        let got = recover::with_retries(
            || {
                let http = self.transport.post(&self.url, &bearer, &body)?;
                if !(200..300).contains(&http.status) {
                    return Err(status_error(http.status, &http.body));
                }
                self.decode(&http.body)
            },
            |_| None,
            |delay| std::thread::sleep(delay),
        );
        let waited = started.elapsed();
        let mut verdicts = got?;
        verdicts.latency = waited;
        self.meter.add(verdicts.usage, waited);
        Ok(verdicts)
    }

    fn name(&self) -> &str {
        &self.model
    }
}

/// The driving model with its calls metered.
pub struct Metered<M: Model> {
    pub inner: M,
    pub meter: Meter,
}

impl<M: Model> Model for Metered<M> {
    fn complete(&self, request: ModelRequest) -> Result<ModelResponse, Error> {
        let started = Instant::now();
        let response = self.inner.complete(request)?;
        self.meter.add(response.usage, started.elapsed());
        Ok(response)
    }

    fn name(&self) -> &str {
        self.inner.name()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use harness::ports::Question;
    use std::collections::BTreeMap;

    fn decision() -> Decision {
        let mut questions = BTreeMap::new();
        questions.insert("matches".to_string(), Question::yes_no("Does it?"));
        Decision { state: vec![Part::Text("a page".into()), Part::Image("data:image/jpeg;base64,AAAA".into())], questions }
    }

    #[test]
    fn both_shapes_encode_and_decode_a_yes_no_question() {
        let client = Decisions::new("k", OPENROUTER_DECISION_MODEL, OPENROUTER_DECISIONS_URL, Wire::OpenRouter);
        let body = client.encode(&decision());
        assert_eq!(body["questions"]["matches"]["type"], "noul");
        assert_eq!(body["state"][1]["image_url"]["url"], "data:image/jpeg;base64,AAAA");
        let got = client.decode(r#"{"model":"m","answers":{"matches":{"type":"noul","noul":0.9}},"usage":{"input_tokens":1200,"output_tokens":0,"cost":0.00012}}"#).unwrap();
        assert_eq!(got.yes("matches"), Some(0.9));
        assert_eq!((got.usage.input_tokens, got.usage.cost), (1200, 0.00012));

        let client = Decisions::new("k", OPENAI_DECISION_MODEL, OPENAI_DECISIONS_URL, Wire::OpenAI);
        let body = client.encode(&decision());
        assert_eq!(body["questions"][0]["type"], "predicate");
        assert_eq!(body["input"][0]["content"][1]["type"], "input_image");
        let got = client.decode(r#"{"model":"gpt-6-luna","answers":[{"type":"predicate","name":"matches","probability":0.2}],"usage":{"input_tokens":900,"output_tokens":0,"input_tokens_details":{"cached_tokens":100}}}"#).unwrap();
        assert_eq!(got.yes("matches"), Some(0.2));
        assert_eq!(got.usage.cached_tokens, 100);
        assert_eq!(status_error(429, r#"{"error":{"message":"slow down"}}"#).kind, ErrorKind::RateLimited);
    }
}
