# Side Eye’s local summary model

The weights are Qwen3.5-2B, quantized to GGUF Q3_K_M by Unsloth. Side Eye downloads this exact file when you ask it to, or a build can have it inside. The original model and the quantization use Apache 2.0. The license accompanies the weights.

- [Qwen model card](https://huggingface.co/Qwen/Qwen3.5-2B)
- [Pinned Unsloth GGUF weights](https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/blob/87e547fc268695ff509f27665c7002e98ed078bc/Qwen3.5-2B-Q3_K_M.gguf)
- SHA-256 `8b049f98461020b7e15797e13413fc63b9b500ffa883c74618b618ecbc2bfccf`

The model runs on llama.cpp’s server (MIT license, in `llama.cpp-LICENSE.txt`). The release download carries one inside the app, built by `Scripts/llama-server.sh` from a pinned commit. Without it Side Eye uses the Homebrew `llama-server`, at `/opt/homebrew/bin/llama-server` on Apple silicon or `/usr/local/bin/llama-server` on Intel. The server must support a Unix socket as its host. The app starts it on demand and stops it after 45 seconds without a request.
