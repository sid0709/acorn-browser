//! A driving-model client for OpenRouter's OpenAI-compatible chat API: it carries screenshots
//! and asks for a JSON object of a given schema.
//!
//! The request body and the response reading are pure functions, tested without a network. The
//! HTTP itself is a [`Transport`] the client is given, so a test uses a stub and production uses
//! [`UreqTransport`]; transport failures retry with backoff through [`crate::recover`].

use std::time::{Duration, Instant};

use serde_json::{Map, Value, json};

use crate::ports::{Error, ErrorKind, Model, ModelRequest, ModelResponse, Role, Usage};
use crate::recover;

/// How long one HTTP attempt may take: a screenshot in, a few hundred tokens out.
pub const REQUEST_TIMEOUT: Duration = Duration::from_secs(120);
/// The most characters of a provider error kept for the message.
const MAX_ERROR_TEXT: usize = 300;

/// One HTTP POST, so the network is swappable. Returns the status, the body, and the server's
/// `Retry-After` header when it sent one. A failure to reach the server at all is a transport
/// error.
pub trait Transport {
    fn post(&self, url: &str, bearer: &str, body: &[u8]) -> Result<HttpResponse, Error>;
}

/// What a transport got back.
#[derive(Clone, Debug)]
pub struct HttpResponse {
    pub status: u16,
    pub body: String,
    pub retry_after: Option<String>,
}

/// The OpenRouter client.
pub struct OpenRouter {
    api_key: String,
    model: String,
    base_url: String,
    /// The reasoning effort sent to the provider (`none`, `low`, `medium`, `high`); empty sends
    /// none.
    reasoning: String,
    transport: Box<dyn Transport + Send + Sync>,
}

impl OpenRouter {
    /// A client for `model` on `base_url`, using `transport` for the network.
    pub fn new(api_key: impl Into<String>, model: impl Into<String>, base_url: impl Into<String>, reasoning: impl Into<String>, transport: Box<dyn Transport + Send + Sync>) -> Self {
        OpenRouter {
            api_key: api_key.into().trim().to_string(),
            model: model.into(),
            base_url: base_url.into().trim_end_matches('/').to_string(),
            reasoning: reasoning.into().trim().to_string(),
            transport,
        }
    }

    /// The provider request body for one call.
    fn body(&self, request: &ModelRequest) -> Value {
        build_body(&self.model, &self.reasoning, request)
    }
}

impl Model for OpenRouter {
    fn complete(&self, request: ModelRequest) -> Result<ModelResponse, Error> {
        if self.api_key.is_empty() {
            return Err(Error::new(ErrorKind::BadRequest, "no OpenRouter API key"));
        }
        let body = serde_json::to_vec(&self.body(&request)).map_err(|e| Error::new(ErrorKind::BadRequest, format!("encode model request: {e}")))?;
        let url = format!("{}/chat/completions", self.base_url);
        let bearer = format!("Bearer {}", self.api_key);
        let started = Instant::now();
        let mut attempts = 0u32;
        let got = recover::with_retries(
            || {
                attempts += 1;
                let http = self.transport.post(&url, &bearer, &body)?;
                parse_response(http.status, &http.body).map_err(|mut e| {
                    // Carry the server's Retry-After onto a rate-limit error for the backoff.
                    if e.kind == ErrorKind::RateLimited && let Some(after) = &http.retry_after {
                        e.message = format!("{}; retry-after {after}", e.message);
                    }
                    e
                })
            },
            |_| None,
            |delay| std::thread::sleep(delay),
        )?;
        Ok(ModelResponse { latency: started.elapsed(), attempts, ..got })
    }

    fn name(&self) -> &str {
        &self.model
    }
}

/// The marker the providers take for a prompt prefix worth caching.
const CACHE_EPHEMERAL: &str = "ephemeral";

/// Builds the chat request body. A message with images, or one that ends a cached part of the
/// prompt, sends its content as parts, with the cache marker on its text.
pub fn build_body(model: &str, reasoning: &str, request: &ModelRequest) -> Value {
    let messages: Vec<Value> = request
        .messages
        .iter()
        .map(|message| {
            let role = role_name(message.role);
            if message.images.is_empty() && !message.cache {
                return json!({"role": role, "content": message.text});
            }
            let mut text = json!({"type": "text", "text": message.text});
            if message.cache {
                text.as_object_mut().unwrap().insert("cache_control".into(), json!({"type": CACHE_EPHEMERAL}));
            }
            let mut parts = vec![text];
            for image in &message.images {
                parts.push(json!({"type": "image_url", "image_url": {"url": image}}));
            }
            json!({"role": role, "content": parts})
        })
        .collect();
    let mut out = Map::new();
    out.insert("model".into(), json!(model));
    out.insert("messages".into(), json!(messages));
    out.insert("usage".into(), json!({"include": true}));
    if !request.schema.is_null() {
        out.insert(
            "response_format".into(),
            json!({"type": "json_schema", "json_schema": {"name": request.schema_name, "strict": true, "schema": request.schema}}),
        );
    }
    if !reasoning.is_empty() {
        out.insert("reasoning".into(), json!({"effort": reasoning}));
    }
    Value::Object(out)
}

/// Reads the provider's answer: the content, the model, the finish reason, and the usage, or an
/// error whose kind says whether a retry can help. OpenRouter answers some failures with 200 and
/// an error object, so the body is read even on a 2xx.
pub fn parse_response(status: u16, payload: &str) -> Result<ModelResponse, Error> {
    let decoded: Value = serde_json::from_str(payload).unwrap_or(Value::Null);
    let usage = read_usage(&decoded);
    let error_message = decoded.get("error").and_then(|e| e.get("message")).and_then(Value::as_str).unwrap_or("");
    let error_code = decoded.get("error").and_then(|e| e.get("code"));

    if !(200..300).contains(&status) {
        return Err(status_error(status, error_message));
    }
    if !error_message.is_empty() || error_code.is_some() {
        let code = error_code.and_then(error_status).unwrap_or(502);
        return Err(status_error(code, error_message));
    }
    let choice = decoded.get("choices").and_then(|c| c.get(0));
    let content = match choice.and_then(|c| c.get("message")).and_then(|m| m.get("content")).and_then(Value::as_str) {
        Some(content) => content.to_string(),
        None => return Err(Error::new(ErrorKind::Server, "the model returned no choices")),
    };
    Ok(ModelResponse {
        content,
        model: decoded.get("model").and_then(Value::as_str).unwrap_or("").to_string(),
        finish_reason: choice.and_then(|c| c.get("finish_reason")).and_then(Value::as_str).unwrap_or("").to_string(),
        usage,
        ..Default::default()
    })
}

fn read_usage(decoded: &Value) -> Usage {
    let u = decoded.get("usage");
    let num = |key: &str| u.and_then(|u| u.get(key)).and_then(Value::as_u64).unwrap_or(0);
    let details = |key: &str| u.and_then(|u| u.get("prompt_tokens_details")).and_then(|d| d.get(key)).and_then(Value::as_u64).unwrap_or(0);
    Usage {
        input_tokens: num("prompt_tokens"),
        output_tokens: num("completion_tokens"),
        cached_tokens: details("cached_tokens"),
        cache_write_tokens: details("cache_write_tokens"),
        cost: u.and_then(|u| u.get("cost")).and_then(Value::as_f64).unwrap_or(0.0),
    }
}

/// The status an error object stands for: OpenRouter puts the real status in the error `code`.
fn error_status(code: &Value) -> Option<u16> {
    let n = code.as_u64().or_else(|| code.as_str().and_then(|s| s.trim().parse().ok()))?;
    (400..=599).contains(&n).then_some(n as u16)
}

/// Turns an HTTP status into an error whose kind says whether a retry can help.
fn status_error(status: u16, message: &str) -> Error {
    let kind = match status {
        401 | 403 => ErrorKind::BadRequest,
        402 => ErrorKind::BadRequest,
        429 => ErrorKind::RateLimited,
        400..=499 => ErrorKind::BadRequest,
        _ => ErrorKind::Server,
    };
    let text = clip(message.trim(), MAX_ERROR_TEXT);
    let message = if text.is_empty() { format!("model request failed ({status})") } else { format!("model request failed ({status}): {text}") };
    Error::new(kind, message)
}

fn role_name(role: Role) -> &'static str {
    match role {
        Role::System => "system",
        Role::User => "user",
        Role::Assistant => "assistant",
    }
}

fn clip(text: &str, max: usize) -> String {
    match text.char_indices().nth(max) {
        Some((end, _)) => format!("{}…", &text[..end]),
        None => text.to_string(),
    }
}

/// The production [`Transport`]: a pooled ureq agent that returns a response for every status
/// (so an error body is read, not swallowed) and honours `HTTPS_PROXY`/`HTTP_PROXY` from the
/// environment. A MITM proxy's CA must be trusted by the process for TLS to pass.
pub struct UreqTransport {
    agent: ureq::Agent,
}

impl Default for UreqTransport {
    fn default() -> Self {
        let mut config = ureq::Agent::config_builder()
            .http_status_as_error(false)
            .timeout_global(Some(REQUEST_TIMEOUT));
        if let Some(proxy) = ureq::Proxy::try_from_env() {
            config = config.proxy(Some(proxy));
        }
        UreqTransport { agent: config.build().into() }
    }
}

impl Transport for UreqTransport {
    fn post(&self, url: &str, bearer: &str, body: &[u8]) -> Result<HttpResponse, Error> {
        let mut response = self
            .agent
            .post(url)
            .header("Authorization", bearer)
            .header("Content-Type", "application/json")
            .send(body)
            .map_err(|e| Error::new(ErrorKind::Transport, format!("call model: {e}")))?;
        let status = response.status().as_u16();
        let retry_after = response.headers().get("retry-after").and_then(|v| v.to_str().ok()).map(str::to_string);
        let text = response.body_mut().read_to_string().map_err(|e| Error::new(ErrorKind::Transport, format!("read model response: {e}")))?;
        Ok(HttpResponse { status, body: text, retry_after })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ports::Message;

    #[test]
    fn the_body_marks_the_cached_system_prompt_and_sets_the_schema() {
        let request = ModelRequest {
            messages: vec![
                Message { role: Role::System, text: "rules".into(), images: vec![], cache: true },
                Message { role: Role::User, text: "look".into(), images: vec!["data:image/png;base64,x".into()], cache: false },
            ],
            schema_name: "step".into(),
            schema: json!({"type": "object"}),
        };
        let body = build_body("openai/gpt-x", "low", &request);
        let system = &body["messages"][0];
        assert_eq!(system["content"][0]["cache_control"]["type"], "ephemeral");
        assert_eq!(body["messages"][1]["content"][1]["image_url"]["url"], "data:image/png;base64,x");
        assert_eq!(body["response_format"]["json_schema"]["strict"], true);
        assert_eq!(body["reasoning"]["effort"], "low");
        assert_eq!(body["usage"]["include"], true);
    }

    #[test]
    fn a_good_response_reads_content_and_usage() {
        let payload = r#"{"model":"openai/gpt-x","choices":[{"message":{"content":"{}"},"finish_reason":"stop"}],
            "usage":{"prompt_tokens":1200,"completion_tokens":40,"cost":0.004,"prompt_tokens_details":{"cached_tokens":1000}}}"#;
        let got = parse_response(200, payload).unwrap();
        assert_eq!(got.content, "{}");
        assert_eq!(got.finish_reason, "stop");
        assert_eq!(got.usage.input_tokens, 1200);
        assert_eq!(got.usage.cached_tokens, 1000);
        assert_eq!(got.usage.cost, 0.004);
    }

    #[test]
    fn errors_carry_the_kind_that_decides_a_retry() {
        assert_eq!(parse_response(429, r#"{"error":{"message":"slow down"}}"#).unwrap_err().kind, ErrorKind::RateLimited);
        assert_eq!(parse_response(400, r#"{"error":{"message":"bad"}}"#).unwrap_err().kind, ErrorKind::BadRequest);
        assert_eq!(parse_response(503, "").unwrap_err().kind, ErrorKind::Server);
        // A failure OpenRouter reports with 200 and an error code.
        let in_body = parse_response(200, r#"{"error":{"message":"no credits","code":402}}"#).unwrap_err();
        assert_eq!(in_body.kind, ErrorKind::BadRequest);
        assert!(in_body.message.contains("402"));
    }

    #[test]
    fn complete_retries_a_server_failure_then_succeeds() {
        use std::sync::Mutex;
        struct Flaky(Mutex<u32>);
        impl Transport for Flaky {
            fn post(&self, _url: &str, _bearer: &str, _body: &[u8]) -> Result<HttpResponse, Error> {
                let mut n = self.0.lock().unwrap();
                *n += 1;
                let status = if *n < 2 { 503 } else { 200 };
                Ok(HttpResponse { status, body: r#"{"choices":[{"message":{"content":"{}"}}]}"#.to_string(), retry_after: None })
            }
        }
        let client = OpenRouter::new("key", "openai/gpt-x", "https://openrouter.test/api/v1", "", Box::new(Flaky(Mutex::new(0))));
        let got = client.complete(ModelRequest { schema: Value::Null, ..Default::default() }).unwrap();
        assert_eq!(got.content, "{}");
        assert_eq!(got.attempts, 2);
    }
}
