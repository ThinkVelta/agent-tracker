# Secret-redaction filter for the PostToolUse(Bash) hook.
#
# Reads the hook payload on stdin and masks secrets in `.tool_response` (the
# PostToolUse field carrying the tool result) before the model and the
# transcript ever see it. Emits the `updatedToolOutput` wrapper ONLY when
# something was actually redacted; otherwise emits nothing (`empty`), so the
# unmodified output passes through untouched (zero churn on the common
# no-secret case).
#
# Two complementary passes:
#   1. value-shape — mask a secret by its recognizable prefix/shape ANYWHERE it
#      appears (so it's caught even when used bare, e.g. in a URL or a CLI flag).
#   2. key-name    — mask the value after a known sensitive KEY in `KEY=VALUE` /
#      `KEY: VALUE` / `"KEY": "VALUE"` form. This catches SHAPELESS secrets
#      (RAILWAY_TOKEN, AUTH_SECRET, …) in the dominant leak vector: env / .env /
#      `printenv` / `export` / config dumps, where key and value appear together.
#
# Edit the patterns below to add/remove tokens and sensitive key names.

def redact:
    # ── 1. value-shape: tokens recognizable by prefix/shape anywhere ────────
    # AI providers (sk-ant- before generic sk- so it isn't shadowed)
    gsub("sk-ant-[A-Za-z0-9_-]{16,}"; "sk-ant-[REDACTED]")              # Anthropic API key
  | gsub("sk-[A-Za-z0-9_-]{16,}"; "sk-[REDACTED]")                      # OpenAI API key (incl. sk-proj-)
    # Supabase
  | gsub("sbp_[A-Za-z0-9]{20,}"; "sbp_[REDACTED]")                      # Supabase access token
  | gsub("sb_secret_[A-Za-z0-9_-]{8,}"; "sb_secret_[REDACTED]")         # Supabase secret key (new format)
  | gsub("eyJ[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+"; "[REDACTED-JWT]")  # JWT (Supabase anon/service keys)
    # Sentry
  | gsub("sntrys_[A-Za-z0-9_-]{8,}"; "sntrys_[REDACTED]")               # Sentry auth token
    # Git hosts
  | gsub("github_pat_[A-Za-z0-9_]{20,}"; "github_pat_[REDACTED]")       # GitHub fine-grained PAT
  | gsub("gh[oprsu]_[A-Za-z0-9]{20,}"; "gh_[REDACTED]")                 # GitHub classic PAT/OAuth/server/user/refresh
  | gsub("glpat-[A-Za-z0-9_-]{20,}"; "glpat-[REDACTED]")                # GitLab PAT
    # Payments
  | gsub("(sk|rk)_(live|test)_[A-Za-z0-9]{16,}"; "[REDACTED-STRIPE-KEY]")  # Stripe secret/restricted key
    # Cloud / SaaS
  | gsub("A(KIA|SIA)[0-9A-Z]{16}"; "[REDACTED-AWS-KEY]")                # AWS access key id (incl. temporary ASIA)
  | gsub("AIza[0-9A-Za-z_-]{35}"; "[REDACTED-GOOGLE-KEY]")              # Google API key
  | gsub("ya29\\.[0-9A-Za-z_-]{20,}"; "[REDACTED-GOOGLE-OAUTH]")        # Google OAuth access token
  | gsub("xox[baprs]-[A-Za-z0-9-]{10,}"; "[REDACTED-SLACK-TOKEN]")      # Slack token (bot/user/app/refresh)
  | gsub("xapp-[A-Za-z0-9-]{10,}"; "[REDACTED-SLACK-TOKEN]")            # Slack app-level token
  | gsub("SG\\.[A-Za-z0-9_-]{16,}\\.[A-Za-z0-9_-]{16,}"; "[REDACTED-SENDGRID-KEY]")  # SendGrid
  | gsub("npm_[A-Za-z0-9]{36}"; "npm_[REDACTED]")                       # npm token
    # PEM private-key blocks (multi-line)
  | gsub("-----BEGIN[A-Z ]*PRIVATE KEY-----[\\s\\S]*?-----END[A-Z ]*PRIVATE KEY-----"; "[REDACTED-PRIVATE-KEY]")
    # URLs / connection strings
  | gsub("(?<pre>[a-zA-Z][a-zA-Z0-9+.-]*://[^/@\\s:]+:)[^/@\\s]+@"; "\(.pre)[REDACTED]@")  # inline credentials (scheme://user:PASSWORD@)
    # ── 2. key-name: value after a known sensitive key ──────────────────────
    # Matches KEY<quote?><:|=><quote?>VALUE and keeps the key+separator, masking
    # the value.
    #
    # What confines the match to one line is the backslash handling in the value
    # group, NOT the [ \t] in the separator group -- that only constrains the gap
    # between the key and the value.
    #
    # This filter runs over the JSON serialization (see tojson below), where a
    # newline is not a newline character but the two literal characters \ and n.
    # Neither is \s, so a naive [^\s"',]+ runs straight through end-of-line and
    # keeps eating following lines until the next space, quote or comma,
    # replacing all of it with a single [REDACTED]. That destroys unrelated
    # output rather than merely over-masking, and leaves no sign anything was
    # removed.
    #
    # Hence the alternation: any character that is not whitespace, quote, comma
    # or backslash, OR a backslash that does not begin a JSON escape. Simply
    # excluding backslash also stops the line-spanning, but then masking halts at
    # a backslash INSIDE the value, so a password like pa55\word\here leaks its
    # tail. The lookahead keeps such values fully masked while still stopping at
    # the \n that ends the line.
  | gsub("(?<k>RAILWAY_TOKEN|AUTH_SECRET|SUPABASE_SERVICE_KEY|SUPABASE_SERVICE_ROLE_KEY|SUPABASE_ANON_KEY|SUPABASE_AUTH_KEY|SUPABASE_DB_PASSWORD|SENTRY_AUTH_TOKEN|OPENAI_API_KEY|ANTHROPIC_API_KEY|AWS_SECRET_ACCESS_KEY|AWS_SESSION_TOKEN|DATABASE_URL|POSTGRES_URL|DB_PASSWORD|DATABASE_PASSWORD|STRIPE_SECRET_KEY|GITHUB_TOKEN|GH_TOKEN|NPM_TOKEN|GOOGLE_API_KEY|SENDGRID_API_KEY)(?<s>[\"']?[ \\t]*[:=][ \\t]*[\"']?)(?<v>(?:[^\\s\"',\\\\]|\\\\(?![nrtu]))+)";
          "\(.k)\(.s)[REDACTED]");

# Why tojson/fromjson instead of tostring: `.tool_response` is not a plain
# string — for Bash it is an object (stdout, stderr, …). Redacting over the
# JSON serialization covers every string field in one pass, and parsing the
# result back means `updatedToolOutput` keeps the tool's output shape, which
# Claude Code validates the replacement against (a flat string would be
# rejected). All replacement strings are quote-free literals, so the
# round-trip cannot break JSON syntax; if it ever did, `fromjson` errors and
# the wrapper script's fail-open design leaves the output unredacted.
(.tool_response | tojson) as $original
| ($original | redact) as $redacted
| if $redacted == $original then empty
  else { hookSpecificOutput: { hookEventName: "PostToolUse",
                               updatedToolOutput: ($redacted | fromjson) } }
  end
