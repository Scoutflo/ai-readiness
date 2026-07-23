# SDK instrumentation notes

Use this to write `./scoutflo-audits/sentry/sdk-instrumentation.md` once the account-side setup in [../SKILL.md](../SKILL.md) is live. Fill in each project's real DSN (from `GET /projects/${SENTRY_ORG}/${PROJECT}/keys/`) and the environment names you seeded. Never put a real DSN or token in a file that leaves your machine unreviewed; the DSN is not a secret Sentry needs kept from the internet (it is designed to be public in client bundles), but treat it as environment-specific configuration, not something to hardcode into source.

Conservative defaults below apply everywhere unless your team makes and records an explicit exception: sampling rates start low and rise only after real traffic proves quota headroom; session replay starts masked; PII capture starts off. Raise any of these only after a reviewed decision, not because a snippet online sets it to `1.0`.

## Detect the runtime before picking a snippet

| Area | What to check | Why it matters |
| --- | --- | --- |
| Runtime | Browser, Node.js, Python, mobile, desktop, edge/serverless | Selects the SDK package and wrapper |
| Framework | Express, Fastify, Next.js, React, Django, FastAPI, mobile framework | Selects the framework integration and transaction naming |
| Deployment | Container, VM, serverless function, edge platform, mobile/desktop build | Selects secret handling, release strategy, source-map or debug-symbol upload path |
| Build tool | Vite, Webpack, Rollup, esbuild, native bundler | Selects the source-map upload plugin |
| Background work | Cron, queue consumers, scheduled jobs | Selects whether cron check-in code is needed |
| AI/LLM libraries | OpenAI, Anthropic, LangChain, Vercel AI SDK, Google GenAI | Selects which AI monitoring integration to add, if any |

If the runtime is unknown, ask for these six answers before writing snippets; a guessed entrypoint produces notes nobody can paste in directly.

## Web frontend (`@sentry/react`; adapt the package name per framework)

```js
// src/instrument.ts: must be the first import in your app's entry file
import * as Sentry from "@sentry/react";

Sentry.init({
  dsn: import.meta.env.VITE_SENTRY_DSN,
  environment: import.meta.env.MODE,
  release: import.meta.env.VITE_APP_VERSION,
  tracesSampleRate: 0.2,       // example, tune to your traffic and quota
  replaysSessionSampleRate: 0.1,
  replaysOnErrorSampleRate: 1.0,
  integrations: [
    Sentry.browserTracingIntegration(),
    Sentry.replayIntegration({ maskAllText: true, blockAllMedia: true }),
  ],
});
```

`sendDefaultPii` is intentionally omitted; leave it unset (defaults to off) until your team makes an explicit, recorded PII decision.

## Node.js / Express (`@sentry/node`)

```js
// instrument.js: must be the first import, before any other module
const Sentry = require("@sentry/node");

Sentry.init({
  dsn: process.env.SENTRY_DSN,
  environment: process.env.NODE_ENV,
  release: process.env.SENTRY_RELEASE,
  tracesSampleRate: 0.2,   // example, tune to your traffic and quota
  integrations: [Sentry.httpIntegration(), Sentry.expressIntegration()],
});

// After your routes are registered:
app.use(Sentry.expressErrorHandler());
```

## Python / FastAPI (`sentry-sdk`)

```python
import sentry_sdk
import os

sentry_sdk.init(
    dsn=os.environ["SENTRY_DSN"],
    environment=os.getenv("SENTRY_ENVIRONMENT", "production"),
    release=os.getenv("SENTRY_RELEASE"),
    traces_sample_rate=0.2,   # example, tune to your traffic and quota
    # AI integrations (openai, anthropic, langchain) auto-enable when those
    # packages are installed; recordInputs/recordOutputs stay off by default.
)
```

## Desktop apps (Electron main/renderer split, as one example of a two-process runtime)

Desktop runtimes with a privileged main process and a sandboxed UI process typically need two Sentry projects and two SDKs. Electron is one instance of this pattern, not the default architecture; apply the same main/renderer split to any comparable desktop framework.

```js
// main process (@sentry/node)
import * as Sentry from "@sentry/node";

Sentry.init({
  dsn: process.env.SENTRY_MAIN_DSN,
  environment: process.env.NODE_ENV ?? "production",
  release: app.getVersion(),
  tracesSampleRate: 0.2,   // example, tune to your traffic and quota
  integrations: [Sentry.childProcessIntegration()],
});
```

```js
// renderer / UI process (@sentry/browser)
import * as Sentry from "@sentry/browser";

Sentry.init({
  dsn: process.env.SENTRY_RENDERER_DSN,
  environment: process.env.NODE_ENV ?? "production",
  release: window.__APP_VERSION__,
  tracesSampleRate: 0.2,
  replaysSessionSampleRate: 0.1,
  replaysOnErrorSampleRate: 1.0,
  integrations: [
    Sentry.replayIntegration({ maskAllText: true, blockAllMedia: true }),
  ],
});
```

Pass the app version across the process boundary through your framework's context bridge or equivalent, rather than reading it independently in each process (keeps `release` consistent across both).

## Mobile (React Native, Android, iOS)

Use the official platform SDK (`@sentry/react-native`, `io.sentry:sentry-android`, `sentry-cocoa`). Set `dsn`, `environment`, and `release`/`dist` from your build pipeline's version and build-number values, keep `tracesSampleRate` conservative, and enable crash-free session tracking. Debug symbol upload (dSYM/ProGuard mapping) runs in CI, matched to the exact build the store releases.

## AI/LLM integrations

Auto-enable in JavaScript by including the matching integration in `integrations: []`:

| Package | Integration |
| --- | --- |
| `openai` | `Sentry.openAIIntegration()` |
| `@anthropic-ai/sdk` | `Sentry.anthropicAIIntegration()` |
| `ai` (Vercel AI SDK) | `Sentry.vercelAIIntegration()` |
| `@langchain/*` | `Sentry.langChainIntegration()` |
| `@google/genai` | `Sentry.googleGenAIIntegration()` |

`tracesSampleRate` must be greater than `0` for any AI spans to appear. The Vercel AI SDK needs per-call opt-in:

```js
await generateText({
  model: openai("gpt-4o"),
  prompt: "...",
  experimental_telemetry: { isEnabled: true },
});
```

In Python, AI integrations for supported packages (OpenAI, Anthropic, LangChain, and others) auto-enable when the package is installed and `traces_sample_rate > 0`.

**PII gate:** do not enable `recordInputs`/`recordOutputs` (JavaScript) or `include_prompts` (Python) without an explicit, recorded decision: prompts and completions can carry user PII.

## Cron check-ins

Once the monitor exists (see `../SKILL.md`, Cron and uptime monitors), the job itself calls the check-in URLs at `in_progress` start, `ok` on success, and `error` on failure. Most SDKs offer a wrapper (`Sentry.cron.instrumentCron` in JavaScript, `sentry_sdk.crons.monitor` in Python) that emits all three automatically around the job body; prefer the wrapper over hand-rolled HTTP calls when your SDK version supports it.

## Verification checklist for the app team

- A real or controlled event lands in the intended project with the correct `environment`, `release`, and service tag.
- If tracing is enabled, a transaction or trace appears with a stable route/operation name, not a raw URL.
- If replay is enabled, a session appears with masking applied as configured.
- If source maps are in scope, a minified stack trace on a real event resolves to readable file and line.
- If AI monitoring is enabled, a real call produces a `gen_ai.*` span with model, token, and latency fields, and no prompt/response text unless that capture was explicitly approved.
