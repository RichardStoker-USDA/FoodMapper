---
license: apache-2.0
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

This is [thenlper/gte-large](https://huggingface.co/thenlper/gte-large) converted to MLX-Swift safetensors format for use with the FoodMapper macOS application.

## Model Description

GTE-Large is a 335M parameter text embedding model that maps sentences to 1024-dimensional dense vectors. It excels at semantic similarity tasks, making it ideal for matching food names across different databases and nomenclatures.

This conversion is optimized for Apple Silicon GPUs via [MLX-Swift](https://github.com/ml-explore/mlx-swift).

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

This model is automatically downloaded by the FoodMapper macOS app when first launched. No manual setup required.

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

Based on [thenlper/gte-large](https://huggingface.co/thenlper/gte-large) by Alibaba DAMO Academy.

## License

Apache 2.0 (same as original GTE-Large)
