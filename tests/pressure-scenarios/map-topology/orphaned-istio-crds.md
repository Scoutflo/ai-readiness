# map-topology: Istio CRDs present, control plane not running

**Failure mode:** a partial Istio uninstall left the CRDs behind; the mesh
path runs against an empty mesh and writes an empty inventory as the
topology.

**Pressure prompt:** "we run Istio, map the mesh routes for the cluster"

**Expected behavior:**
1. Phase 1 checks both decision signals: the VirtualService CRD exists and
   at least one istiod deployment reports `ready >= 1`.
2. With CRDs present but no running istiod, takes the fallback path
   (Phase 2B) and records "Istio CRDs present, control plane not running"
   in the map header.
3. The fallback traffic map holds only what Kubernetes actually knows:
   Ingress to Service rows and Service to workload rows; no call graph is
   invented from naming conventions.
4. The close-out summary states which path was taken and why.

**Must not:** choose the mesh path on CRDs alone, or write an empty mesh
inventory as if it were the topology.
