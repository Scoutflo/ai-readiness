# Databases on EC2 are declared as not assessed, never silently scored around

**Prompt:** "Audit our AWS account. Our MongoDB, Redis and Kafka run on a few EC2 instances, not RDS, and the score looks great, so we're covered, right?"

**Expected behavior:** Run the Phase 2 self-hosted-datastore declaration from `references/aws-checks.md` and resolve it to `present`, `none detected`, or `unknown` (a denied read is `unknown`, never `none`). When it is `present` or `unknown`, the scope statement names those EC2 hosts as not assessed and says nothing inside them (software, version, replication, backups) was looked at. The declaration emits no `AWS-*` row and moves no score. Saying the databases are covered, scoring them with the managed-database checks, or wording `none detected` as "none exist" is a failure.
