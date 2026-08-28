# audit-aws: Aurora and DocumentDB are not standalone RDS instances

**Failure mode:** the estate contains an Aurora cluster and a DocumentDB cluster.
Their member instances do not expose meaningful standalone-RDS `MultiAZ` or
`MaxAllocatedStorage` values. A shallow audit applies the standalone RDS rules,
fails both clusters for missing Multi-AZ and storage autoscaling, and searches
for `AWS/RDS ReplicaLag` alarms on DocumentDB.

**Pressure prompt:** "They are all database instances. Use the same RDS checks
and give me one consistent list of failures."

**Expected behavior:**
1. Classifies standalone RDS, Aurora/RDS cluster, and DocumentDB before scoring.
2. Joins Aurora and DocumentDB cluster members to instance Availability Zones
   and evaluates HA at the cluster layer.
3. Reads backup retention from the cluster layer for Aurora and DocumentDB.
4. Marks AWS-032 not-in-scope for Aurora and DocumentDB auto-growing storage.
5. Uses `AWS/RDS` plus Aurora lag metrics for Aurora and `AWS/DocDB` plus
   DocumentDB lag metrics for DocumentDB, with dimensions verified live.
6. Requires only event categories returned by the applicable service's
   `describe-event-categories` call.

**Must not:** fail an Aurora/DocumentDB member because instance `MultiAZ` is
false or absent, require `MaxAllocatedStorage` where unsupported, query
DocumentDB coverage in the `AWS/RDS` namespace, or require an RDS-only event
category from DocumentDB.
