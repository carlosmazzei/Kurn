# Model catalog

`model-catalog-v1.json` lets reviewed model facts reach the app between releases. The app
fetches it from this repository's default branch at most once a day, and only while the selected
summary/chat provider is a cloud vendor with a key. It applies the facts over the catalogs compiled
into the app. See "Agent harness" in `CLAUDE.md` and `ModelCatalogDocument` in
`Packages/AgentHarness`.

## Format

```json
{
  "format": "kurn.model-catalog",
  "schema": 1,
  "version": "2026-11-14",
  "models": {
    "gpt-5": {
      "context": 400000,
      "maxOutput": 128000,
      "limit": "combined",
      "tools": "supported",
      "reasoning": "supported",
      "imageInput": "supported",
      "price": { "input": 1.25, "output": 10, "cacheRead": 0.1 }
    }
  }
}
```

Every field of a model is optional. A field that is left out falls back to the bundled fact.

- **Model key:** the exact model ID, lowercase, without a vendor prefix. A `-yyyy-mm-dd` snapshot
  of a listed ID uses the same entry.
- **`context`, `maxOutput`, `limit`:** the context window in tokens, the output limit, and whether
  the window covers input only (`input`) or input and output together (`combined`).
- **`tools`, `reasoning`, `imageInput`:** `supported`, `unsupported` or `unknown`.
- **`price`:** list prices in USD per million input and output tokens. `cacheRead` and
  `cacheWrite` are multiples of the input rate.

## Rules the app enforces

The app refuses the whole document if any rule is broken.

- At most 256 KiB and 2,000 models.
- Model IDs use only lowercase letters, digits and `._:-`.
- `context` is between 1,024 and 20,000,000 tokens. `maxOutput` is no larger than `context`.
- Prices are between 0 and 10,000. Cache multipliers are between 0 and 10.
- `version` is no older than the catalogs bundled in the app or the catalog the app already
  applied, and no more than two days in the future.

## Changing it

1. Bump `version` to the date of the review.
2. Cite the vendor's documentation for every new or changed number in the pull request.
3. Merge the change to the default branch. Apps pick it up within a day.

`ModelCatalogDocumentTests` checks that every fact the file repeats from the bundled catalogs
still agrees with them.
