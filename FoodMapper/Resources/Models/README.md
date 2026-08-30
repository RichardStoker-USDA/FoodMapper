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

This is an MLX-Swift float16 BERT SafeTensors conversion of [thenlper/gte-large](https://huggingface.co/thenlper/gte-large) at revision [`4bef63f39fcc5e2d6b0aae83089f307af4970164`](https://huggingface.co/thenlper/gte-large/tree/4bef63f39fcc5e2d6b0aae83089f307af4970164). FoodMapper pins the converted artifact at `200d1bf79e6a152736fe1517703d0079a0bd16fa`. That revision corrects the artifact card license to MIT and retains the six payload objects from `0b7a78872ae6fd502fe2db3273b1b3e065a3d9db`.

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

FoodMapper prompts you to download this model before default matching. The download starts only after approval. FoodMapper checks the files against the bundled manifest before making the model available. Built-in database rows ship with the app; their GTE-Large embeddings are computed and cached on first use.

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

Based on [thenlper/gte-large](https://huggingface.co/thenlper/gte-large), revision `4bef63f39fcc5e2d6b0aae83089f307af4970164`.

## License

The upstream source and pinned artifact card both declare the MIT License. FoodMapper validates the fixed payload manifest independently. Keep the source citation and MIT notice with any redistributed conversion.
