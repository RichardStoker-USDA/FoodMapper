---
license: mit
language:
- en
library_name: mlx
tags:
- sentence-transformers
- sentence-similarity
- feature-extraction
- food
- embeddings
- mlx
- apple-silicon
base_model: thenlper/gte-large
pipeline_tag: sentence-similarity
---

# FoodMapper GTE-Large (MLX Format)

This is [thenlper/gte-large](https://huggingface.co/thenlper/gte-large) at revision [`4bef63f39fcc5e2d6b0aae83089f307af4970164`](https://huggingface.co/thenlper/gte-large/tree/4bef63f39fcc5e2d6b0aae83089f307af4970164), converted to MLX-Swift float16 BERT safetensors for use with the FoodMapper macOS application.

## Model Description

GTE-Large is a 335M parameter text embedding model that maps sentences to 1024-dimensional dense vectors. FoodMapper uses it to compare food descriptions across databases and naming systems.

The converted weights run on Apple Silicon through [MLX-Swift](https://github.com/ml-explore/mlx-swift).

## Intended Use

- Semantic food name matching (e.g., matching "granny smith apple" to "Apple, raw, with skin")
- Food database harmonization between USDA FoodData Central, FooDB, and custom datasets
- General text similarity on Apple Silicon Macs

## Model Details

| Property | Value |
|----------|-------|
| Parameters | 335M |
| Embedding Dimension | 1024 |
| Max Sequence Length | 512 |
| Architecture | BERT |
| Precision | float16 |
| Format | safetensors |

## Files

- `gte-large.safetensors` - Model weights in safetensors format (~670MB)
- `config.json` - Model architecture configuration
- `tokenizer.json` - Tokenizer vocabulary and settings
- `tokenizer_config.json` - Tokenizer configuration
- `vocab.txt` - WordPiece vocabulary
- `special_tokens_map.json` - Special token mappings

## Usage with FoodMapper

FoodMapper prompts you to download this model before matching. It downloads only after you approve the prompt, and checks the downloaded files against the pinned manifest before making the model available. Built-in database rows ship with the app; their GTE-Large embeddings are computed and cached on first use.

## Usage with MLX-Swift

```swift
import MLX
import MLXNN

// Load weights
let weights = try loadArrays(url: modelURL)
let parameters = ModuleParameters.unflattened(weights)
try model.update(parameters: parameters, verify: .none)
```

## Pooling

GTE models use **mean pooling** over token embeddings (not CLS token pooling). The attention mask should be applied before averaging:

```swift
func meanPooling(_ hiddenState: MLXArray, attentionMask: MLXArray) -> MLXArray {
    let maskExpanded = attentionMask.expandedDimensions(axis: -1)
        .asType(hiddenState.dtype)
    let sumEmbeddings = (hiddenState * maskExpanded).sum(axis: 1)
    let sumMask = MLX.maximum(maskExpanded.sum(axis: 1), MLXArray(1e-9))
    return sumEmbeddings / sumMask
}
```

## Original Model

Based on [thenlper/gte-large](https://huggingface.co/thenlper/gte-large) by Alibaba DAMO Academy, revision `4bef63f39fcc5e2d6b0aae83089f307af4970164`.

## License

The source model card for this revision declares the MIT License. Keep the source citation and MIT notice with any redistributed conversion.
