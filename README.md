# proba
Validate product market fit quickly. Build your idea get out of the box capability to build landing page. Market it on the digital platforms like meta, google, X. Get analytics and take action based on the metrics to complete the loop. Action like changing the campaign based on analytics and dropping the idea can be supported. Fast and closed loop.

## Run the whole platform locally

One command starts the Hub, web app, audit pipeline, audit API and the metrics pipeline (stub data) on your machine (add `--memory` for the memory service, `--portal` for Proba Insights), and `local/verify.sh` checks it against the design. See [docs/LOCAL_TESTING.md](docs/LOCAL_TESTING.md).

```bash
cd local && ./up.sh && ./seed.sh && ./verify.sh
```

The local stack is locked down: ports on `127.0.0.1` only, no default passwords (`./up.sh` generates random ones into `local/.env`), Redis with an ACL user and password, and least-privilege ClickHouse users. See [Security of the local stack](docs/LOCAL_TESTING.md#security-of-the-local-stack). Branch protection for `main`: [docs/BRANCH_PROTECTION.md](docs/BRANCH_PROTECTION.md).
