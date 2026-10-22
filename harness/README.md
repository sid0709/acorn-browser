# harness

A general-purpose agent harness for a browser that does any task given in chat. Pure image
based: the browser sends a screenshot, the harness answers with the next actions.

The design: the model plans and recovers; the harness observes, verifies, remembers, and decides
when the run is done, stuck, or needs the person. Verification never blocks execution. The gate
slot exists from the first step; its rules come last.

```bash
cargo build
```

## Steps

One step, one commit. Build must pass; tests stay minimal.

**A. Skeleton**
- [x] 1. Crate, empty modules, build passes
- [x] 2. Observation struct
- [x] 3. Action struct and batches
- [x] 4. Traits: driving model, decision model, browser
- [x] 5. Task struct
- [x] 6. Session struct

**B. Minimal loop**
- [x] 7. Step: observe, model, actions (gate slot, pass-through)
- [x] 8. End: step limit
- [x] 9. Unchanged-screen detection
- [x] 10. Repeated-failure detection
- [x] 11. Example binary: fake model + fake browser, one full run

**C. Model calls**
- [x] 12. System prompt (cache marker)
- [x] 13. Observation text
- [x] 14. Reply schema and parsing
- [x] 15. One repair call on a bad reply
- [x] 16. HTTP retry with backoff
- [x] 17. OpenRouter client

**D. Memory**
- [x] 18. Turn history, image lifetime
- [x] 19. Fold old turns to one line
- [x] 20. Compact on token budget
- [x] 21. Context overflow: compact and retry

**E. Verification**
- [x] 22. Checkpoint: expected screen after a batch
- [x] 23. Skip the model when the checkpoint holds
- [x] 24. Async review, no waiting
- [x] 25. Abort the batch on a wrong fill
- [x] 26. Point check before a plan
- [x] 27. Missed-click guidance

**F. To-do and map**
- [ ] 28. To-do list from the survey
- [ ] 29. Update from reviews
- [ ] 30. Settled stretches, skip re-shooting
- [ ] 31. Partial invalidation by signature

**G. Intervention and report**
- [ ] 32. User message queue
- [ ] 33. Question queue (keep going)
- [ ] 34. End report
- [ ] 35. Trace, tracesum-compatible

**H. Gate**
- [ ] 36. Verify "done"
- [ ] 37. Verify "stop"
- [ ] 38. Irreversible actions and the safe flag
- [ ] 39. Fixed rules
