// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The executable entry point. Everything of substance lives in DoMoCLI; this is
// the ArgumentParser root plus the async entry the roadmap's "domo/: the
// executable, ArgumentParser root plus DoMoCLI.run()" line describes.

import DoMoCLI

await DoMoCodeCommand.run()
