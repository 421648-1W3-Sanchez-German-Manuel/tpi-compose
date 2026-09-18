# What every location that forwards to the gateway needs. In an include so
# none of them forgets it: a location without X-Forwarded-For silently breaks
# the per-IP rate limit (the gateway sees nginx's IP and puts everyone in the
# same bucket), and that only shows up when someone runs out of logins.

proxy_http_version 1.1;
proxy_set_header Connection "";

proxy_set_header Host              $host;
proxy_set_header X-Real-IP         $remote_addr;
proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header X-Forwarded-Host  $host;

# The X-Principal-Type / X-User-* are NOT cleaned here on purpose:
# IdentityPropagationFilter in the gateway does that, erasing them from the
# incoming request before adding its own. Doing it in two places invites
# someone to later "simplify" the gateway's one, which is the one that matters.

# Shorter than the gateway's TimeLimiter timeout (3 s) makes no sense: the
# gateway cuts first and answers 503 with Retry-After. This is the network
# behind it, so nginx does not hang if the gateway stops answering.
proxy_connect_timeout 5s;
proxy_send_timeout    30s;
proxy_read_timeout    30s;

# The gateway returns problem+json on errors; nginx must not replace it with
# its HTML page.
proxy_intercept_errors off;
