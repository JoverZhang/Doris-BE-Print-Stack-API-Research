# Writing Guidelines

Use common words, short sentences, stable terms, and visible logic.

Write for readers who scan and may not be native English speakers:

- Start with the conclusion.
- State the reason next.
- Give the example after that.
- Put edge cases last.
- Use one term for one concept.
- Keep necessary technical terms.
- Remove decorative words.
- Avoid idioms and cultural jokes.
- Avoid double negatives and nested `unless`.

Use a list when several lines share the same subject. This keeps the subject
stable without repeating it.

Example:

```text
The job:

- compiles the script
- runs the script
- writes the result
```

Prefer this:

```text
We delayed the feature because the integration still has problems.
```

Not this:

```text
The implementation of the feature was delayed due to unresolved integration issues.
```

Prefer this:

```text
Engineering time is limited.
The daemon API is still unstable.
We should finish the integration layer first.
Then we can build the dashboard.
```

Not this:

```text
Given the limited engineering capacity and the unstable daemon API, we should postpone the dashboard work until the integration layer becomes reliable enough for production use.
```

Prefer this:

```text
Clear the cache before deployment.
Otherwise, users may see old records.
```

Not this:

```text
Unless the cache is not invalidated before deployment, stale records may continue to be served.
```

Prefer this:

```text
The parser normalizes the AST before type checking.
```

Not this:

```text
The parser facilitates the normalization of the AST prior to the commencement of type checking.
```
