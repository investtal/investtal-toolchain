# jenkins — toolchain CI

Jenkins pipelines that gate **investtal-toolchain** tools (not product apps).

## Why

Install scripts, update paths, and CLIs that land on every engineer’s machine need a CI gate before we trust them. Product repos have their own Jenkinsfiles; this folder is for **the toolchain itself**.

## Contents

| File | Purpose |
|------|---------|
| [`Jenkinsfile`](Jenkinsfile) | 9cc: unit tests (`9cc/9cc.test.sh`), update smoke (`9cc/smoke.sh`), optional macOS agent |

## Local equivalent

```sh
bash 9cc/9cc.test.sh && bash 9cc/smoke.sh
```

Tool docs: [`../9cc/README.md`](../9cc/README.md).
