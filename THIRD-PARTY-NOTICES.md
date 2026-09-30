# Third-Party Notices

The WaifuClaw iOS app itself is proprietary software — see `LICENSE` (all rights reserved). The following source project informed the new native memory graph. Its copyright and license notice is preserved here; this does not relicense the rest of the iOS application.

## NeuralMemory — graph-memory concepts adapted for iPhone

Source: [`grimmjoww/neural-memory`](https://github.com/grimmjoww/neural-memory), reviewed commit `2015cb9b0973a6fe14a3bc547c932d64d6ced203`. The native Swift/SQLite implementation is a limited adaptation, **not** the upstream Python or Pro implementation. Its exact feature mapping and limitations are documented in `WaifuClaw/Local/Memory/UPSTREAM.md`.

```text
MIT License

Copyright (c) 2024 NeuralMemory Contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Policy

When code from DeerFlow, Hermes, or another third party is vendored, add its copyright and full license here before distribution. The desktop/backend project has its own license notices; its Python runtime is **not** bundled in this iOS target.
