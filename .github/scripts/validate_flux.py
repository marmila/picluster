#!/usr/bin/env python3
"""Validate what Flux would apply for one cluster, without a cluster.

For every Flux Kustomization defined under kubernetes/clusters/<env>/:
  1. build its path with kustomize (as kustomize-controller does),
  2. substitute ${VARS} from the cluster-settings ConfigMap (unknown ones, such
     as secrets, get a placeholder),
  3. write the result to <out>/manifests/<name>.yaml for kubeconform.
Then, for every HelmRelease found, render its chart at the pinned version with
`helm template`, using spec.values plus valuesFrom ConfigMaps from the same
build. This catches a chart version that does not exist and values the new
chart version rejects.

Exit code 1 if any build or chart render fails. Usage:
  validate_flux.py --env prod --out /tmp/flux-validate [--skip-helm]
"""

import argparse
import copy
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parents[2]
VAR_RE = re.compile(r"\$\{([A-Za-z0-9_]+)(?::=([^}]*))?\}")
PLACEHOLDER = "placeholder"


def load_docs(text):
    return [d for d in yaml.safe_load_all(text) if isinstance(d, dict)]


def cluster_kustomizations(env):
    """Flux Kustomizations (name, path) declared for this cluster."""
    # Flux syncs kubernetes/clusters/<env>. With no kustomization.yaml at that
    # level it builds each subfolder's kustomization.yaml, so files not listed
    # there are never applied: read the cluster the same way.
    root = REPO / "kubernetes" / "clusters" / env
    dirs = [root] if (root / "kustomization.yaml").exists() else sorted(
        d for d in root.iterdir() if (d / "kustomization.yaml").exists())
    found = []
    for d in dirs:
        res = kustomize_build(d.relative_to(REPO))
        if res.returncode != 0:
            sys.exit(f"cannot build {d.relative_to(REPO)}:\n{res.stderr}")
        for doc in load_docs(res.stdout):
            if doc.get("kind") == "Kustomization" and doc.get("apiVersion", "").startswith("kustomize.toolkit.fluxcd.io"):
                found.append((doc["metadata"]["name"], doc["spec"]["path"], doc["spec"].get("targetNamespace")))
    return found


def cluster_settings(env):
    f = REPO / "kubernetes" / "clusters" / env / "config" / "cluster-settings.yaml"
    for doc in load_docs(f.read_text(encoding="utf-8")):
        if doc.get("kind") == "ConfigMap":
            return {k: str(v) for k, v in (doc.get("data") or {}).items()}
    return {}


def substitute(text, settings):
    """Flux postBuild substitution, per document; honours substitute: disabled."""
    out = []
    for raw in re.split(r"(?m)^---\s*$", text):
        if "kustomize.toolkit.fluxcd.io/substitute: disabled" in raw:
            out.append(raw)
            continue
        out.append(VAR_RE.sub(lambda m: settings.get(m.group(1), m.group(2) if m.group(2) is not None else PLACEHOLDER), raw))
    return "---".join(out)


def kustomize_build(path):
    # KUSTOMIZE="kubectl kustomize" works locally when the kustomize binary is missing
    cmd = os.environ.get("KUSTOMIZE", "kustomize build").split()
    return subprocess.run(
        cmd + ["--load-restrictor", "LoadRestrictionsNone", str(REPO / path)],
        capture_output=True, text=True, encoding="utf-8",
    )


def deep_merge(base, extra):
    for k, v in extra.items():
        if isinstance(v, dict) and isinstance(base.get(k), dict):
            deep_merge(base[k], v)
        else:
            base[k] = copy.deepcopy(v)
    return base


def chart_source(hr, index):
    """Return (helm chart reference, version, extra helm args) or raise ValueError."""
    ns = hr["metadata"].get("namespace", "flux-system")
    spec = hr["spec"]
    if "chartRef" in spec:
        ref = spec["chartRef"]
        src = index.get((ref["kind"], ref.get("namespace", ns), ref["name"]))
        if not src:
            raise ValueError(f"{ref['kind']} {ref['name']} not found in any build")
        tag = (src["spec"].get("ref") or {}).get("tag")
        if not tag:
            raise ValueError(f"OCIRepository {ref['name']} has no ref.tag")
        return src["spec"]["url"], tag, []
    cs = spec["chart"]["spec"]
    sref = cs["sourceRef"]
    src = index.get((sref["kind"], sref.get("namespace", ns), sref["name"]))
    if not src:
        raise ValueError(f"{sref['kind']} {sref['name']} not found in any build")
    url = src["spec"]["url"]
    if src["spec"].get("type") == "oci" or url.startswith("oci://"):
        return f"{url.rstrip('/')}/{cs['chart']}", cs.get("version"), []
    return cs["chart"], cs.get("version"), ["--repo", url]


def helm_values(hr, index):
    ns = hr["metadata"].get("namespace", "flux-system")
    values = {}
    for vf in hr["spec"].get("valuesFrom") or []:
        if vf.get("kind") != "ConfigMap":
            continue  # Secrets come from Vault at runtime
        cm = index.get(("ConfigMap", ns, vf["name"]))
        if not cm:
            if vf.get("optional"):
                continue
            raise ValueError(f"valuesFrom ConfigMap {vf['name']} not found in the build")
        data = (cm.get("data") or {}).get(vf.get("valuesKey", "values.yaml"))
        if data is None:
            continue
        if vf.get("targetPath"):
            continue  # single-value injection, not needed to render
        deep_merge(values, yaml.safe_load(data) or {})
    deep_merge(values, hr["spec"].get("values") or {})
    return values


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--env", default="prod")
    ap.add_argument("--out", required=True)
    ap.add_argument("--skip-helm", action="store_true")
    ap.add_argument("--kube-version", default="1.37.0")
    args = ap.parse_args()

    out = Path(args.out)
    (out / "manifests").mkdir(parents=True, exist_ok=True)
    settings = cluster_settings(args.env)
    failures = []
    index = {}
    releases = []

    kss = cluster_kustomizations(args.env)
    print(f"Building {len(kss)} Flux Kustomizations for '{args.env}'")
    for name, path, target_ns in kss:
        res = kustomize_build(path)
        if res.returncode != 0:
            failures.append(f"kustomize build {name} ({path}):\n{res.stderr.strip()}")
            print(f"  FAIL {name}")
            continue
        text = substitute(res.stdout, settings)
        (out / "manifests" / f"{name}.yaml").write_text(text, encoding="utf-8")
        for doc in load_docs(text):
            md = doc.setdefault("metadata", {})
            # Flux applies into spec.targetNamespace when set; the namespace
            # matters here only to match HelmReleases with their sources.
            if target_ns:
                md["namespace"] = target_ns
            ns = md.get("namespace", "default")
            index[(doc["kind"], ns, md.get("name"))] = doc
            if doc["kind"] == "HelmRelease":
                releases.append((name, doc))
        print(f"  ok   {name}")

    if not args.skip_helm:
        print(f"\nRendering {len(releases)} HelmReleases")
        with tempfile.TemporaryDirectory() as tmp:
            # Clean helm config: no local repos or registry logins (public charts only)
            env = dict(os.environ)
            for var, sub in (("HELM_CONFIG_HOME", "config"), ("HELM_CACHE_HOME", "cache"), ("HELM_DATA_HOME", "data")):
                env[var] = str(Path(tmp) / "helm" / sub)
            env["HELM_REGISTRY_CONFIG"] = str(Path(tmp) / "helm" / "registry.json")
            env["HELM_REPOSITORY_CONFIG"] = str(Path(tmp) / "helm" / "repositories.yaml")
            env["HELM_REPOSITORY_CACHE"] = str(Path(tmp) / "helm" / "repository")
            env["DOCKER_CONFIG"] = str(Path(tmp) / "docker")  # helm also reads docker logins
            for ks_name, hr in releases:
                label = f"{hr['metadata'].get('namespace')}/{hr['metadata']['name']}"
                try:
                    chart, version, extra = chart_source(hr, index)
                    values = helm_values(hr, index)
                except (ValueError, KeyError) as e:
                    failures.append(f"HelmRelease {label} (Kustomization {ks_name}): {e}")
                    print(f"  FAIL {label}")
                    continue
                vfile = Path(tmp) / "values.yaml"
                vfile.write_text(yaml.safe_dump(values), encoding="utf-8")
                cmd = ["helm", "template", hr["spec"].get("releaseName", hr["metadata"]["name"]), chart,
                       "--namespace", hr["spec"].get("targetNamespace", hr["metadata"].get("namespace", "default")),
                       "--kube-version", args.kube_version, "--include-crds", "-f", str(vfile)] + extra
                if version:
                    cmd += ["--version", str(version)]
                res = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", env=env)
                if res.returncode != 0:
                    failures.append(f"HelmRelease {label} chart {chart} {version}:\n{res.stderr.strip()[-2000:]}")
                    print(f"  FAIL {label} ({chart} {version})")
                else:
                    print(f"  ok   {label} ({chart} {version})")

    if failures:
        print(f"\n{len(failures)} problem(s):\n")
        for f in failures:
            print(f"- {f}\n")
        return 1
    print("\nAll builds and charts OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
