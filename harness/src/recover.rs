//! What to do when a model call fails: retry with backoff, ask the model to repair a bad reply,
//! and compact when the context window is exceeded.
