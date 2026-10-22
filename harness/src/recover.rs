//! What to do when a model call fails: ask the model to repair a reply that did not parse
//! (here), retry a transport failure with backoff (`retry_delay`), and, later, compact when the
//! context window is exceeded.

use serde_json::Value;

use crate::model::{self, Reply};
use crate::ports::{Error, Message, Model, ModelRequest, Role, Usage};

/// How many times a step asks the model: the first try, then one repair of a reply that did not
/// parse.
pub const MAX_ASK_ATTEMPTS: usize = 2;

/// A model answer that parsed, with the raw text and what the attempts cost together.
#[derive(Clone, Debug)]
pub struct Answer {
    pub reply: Reply,
    pub content: String,
    pub usage: Usage,
    /// How many requests were sent (a repair makes two).
    pub attempts: u32,
}

/// Why `ask` gave up.
#[derive(Debug)]
pub enum AskError {
    /// The model call itself failed; `recover` does not retry transport here, the client does.
    Model(Error),
    /// The reply did not parse, even after a repair. Carries the last parse error and the cost
    /// so far, so the caller can still charge it.
    Reply { why: String, usage: Usage },
}

/// Asks the model for one step and reads its reply. When the reply does not parse, the model is
/// asked once more, shown its own answer and told to send only the JSON; a reply cut off for
/// length is told to answer shorter. The repair call adds only its two messages, so the prompt
/// prefix stays cached.
pub fn ask(model: &(dyn Model + Send + Sync), mut messages: Vec<Message>, schema_name: &str, schema: Value) -> Result<Answer, AskError> {
    let mut usage = Usage::default();
    let mut last = String::new();
    for attempt in 0..MAX_ASK_ATTEMPTS {
        let response = model
            .complete(ModelRequest { messages: messages.clone(), schema_name: schema_name.to_string(), schema: schema.clone() })
            .map_err(AskError::Model)?;
        usage.add(response.usage);
        match model::parse_reply(&response.content) {
            Ok(reply) => {
                return Ok(Answer { reply, content: response.content.trim().to_string(), usage, attempts: attempt as u32 + 1 });
            }
            Err(why) => {
                last = why.clone();
                if attempt + 1 == MAX_ASK_ATTEMPTS {
                    break;
                }
                let note = if response.finish_reason == "length" {
                    "That answer was cut off, so it was not valid JSON. Answer again, shorter, with only the JSON object.".to_string()
                } else {
                    format!("That answer was not accepted: {why}. Answer again with only the JSON object, and nothing else.")
                };
                messages.push(Message { role: Role::Assistant, text: response.content, ..Default::default() });
                messages.push(Message { role: Role::User, text: note, ..Default::default() });
            }
        }
    }
    Err(AskError::Reply { why: last, usage })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ports::ModelResponse;
    use serde_json::json;
    use std::sync::Mutex;

    struct Script {
        replies: Vec<&'static str>,
        seen: Mutex<Vec<String>>,
    }

    impl Model for Script {
        fn complete(&self, request: ModelRequest) -> Result<ModelResponse, Error> {
            let mut seen = self.seen.lock().unwrap();
            let content = self.replies[seen.len().min(self.replies.len() - 1)].to_string();
            seen.push(request.messages.last().unwrap().text.clone());
            Ok(ModelResponse { content, usage: Usage { input_tokens: 10, cost: 0.001, ..Default::default() }, ..Default::default() })
        }
        fn name(&self) -> &str {
            "script"
        }
    }

    fn base() -> Vec<Message> {
        vec![Message { role: Role::User, text: "look".into(), ..Default::default() }]
    }

    #[test]
    fn a_bad_reply_is_repaired_once() {
        let model = Script { replies: vec!["sorry, I cannot do JSON", r#"{"status":"working","message":"ok","actions":[]}"#], seen: Mutex::new(Vec::new()) };
        let answer = ask(&model, base(), "step", json!({})).unwrap();
        assert_eq!(answer.reply.status, crate::run::Status::Working);
        assert_eq!(answer.attempts, 2);
        assert_eq!(answer.usage.input_tokens, 20);
        let seen = model.seen.lock().unwrap();
        assert_eq!(seen.len(), 2);
        assert!(seen[1].contains("Answer again with only the JSON object"));
    }

    #[test]
    fn two_bad_replies_give_up_but_keep_the_cost() {
        let model = Script { replies: vec!["nope", "still nope"], seen: Mutex::new(Vec::new()) };
        match ask(&model, base(), "step", json!({})) {
            Err(AskError::Reply { usage, .. }) => assert_eq!(usage.input_tokens, 20),
            other => panic!("expected a reply error, got {other:?}"),
        }
    }
}
