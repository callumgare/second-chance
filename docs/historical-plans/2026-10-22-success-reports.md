# Success reports

A frozen record of the plan, as implemented on 2026-10-22. What the code does
now is in [docs/failure-reports.md](../failure-reports.md#success-reports).

## Why

Sentry only heard about failures: "nothing is sent unless something fails".
That showed what breaks, but there was no count of what works, so no success
rate either. We couldn't tell which games are known to work, or whether a
game from Steam starts more reliably than the same game from a disc.

## Options weighed

| Option | For | Against |
| --- | --- | --- |
| Sentry Application Metrics (GA May 2026) | Already linked, statically, in the app and wrapps (sentry-cocoa 9.30.2; metrics need 9.12 or later). Same DSN, gating and privacy story. 5 GB included on every plan | Counts, not people: weak at unique players, funnels and retention |
| TelemetryDeck | Apple-focused, privacy-first. Unique users, funnels and retention built in | A second vendor and disclosure. The free tier was cut to 50k signals a month for new accounts in July 2026, and data stops at the cap |
| Aptabase | Open source, simple, can be self-hosted | 20k events a month free. Least analysis power |
| PostHog | 1M events a month free, a full product-analytics suite | A large iOS-first SDK. More privacy surface than wanted |
| Own endpoint (a Worker and a database, or Umami/Plausible's event API) | Full control, no SDK | We run it and write every query |
| Firebase / Google Analytics | — | Wrong for the privacy stance and the static linking |

Static linking in wrapps looked like a constraint at first. A wrapp's
`Contents/Frameworks` is replaced by the engine's. The constraint is soft:
`setupWineFramework` could keep an SDK's framework. It didn't decide anything,
because Sentry won on avoiding a second vendor and a second disclosure.

## Decisions

- **Opt-in, asked once, after the first successful build** and before the
  folder picker: by then the person has seen a game work. It is a page in
  the main window, not an alert. Yes and no carry equal weight: neither
  button is the default. A yes gets a thank-you page.
  Settings changes it afterwards.
- **Builds and launches, both outcomes.** Counting only successes, and
  reading failures from failure reports, mixes two populations under two
  settings, which skews a rate. Counting both from the same opted-in people
  gives a real success rate per game. Launches are counted as well as builds
  because a game that builds but won't play would otherwise look like it
  works.
- **Nothing before the answer is counted, or held over.** A first build that
  fails is never followed by the question. That failure is still a failure
  report. Buffering it in case of a later yes would mean keeping unsent data
  on behalf of someone who hasn't agreed to send it.
- **Anonymous.** `beforeSendMetric` keeps an allow-list of attributes, which
  drops the installation ID the failure reports carry, the Mac's details and
  the scope tags.
- **Wrapps learn their source** from a new `GameSource` key in
  `AppSettings.plist`. Older wrapps report `unknown`.
