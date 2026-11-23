# Basis-Image des ISO-Builds. build.yml startet build/build.sh in diesem Image, gebaut wird aus dieser
# Datei nichts. Der Digest legt das Image fest: Ein neues Image unter demselben Tag ändert den Build
# erst mit einem Commit. Dependabot schlägt neue Digests als PR vor, die CI baut und testet sie.
FROM ubuntu:26.04@sha256:d66b366dac61b575bee2aef07e9c26e8070096fbe84a3d4d3eb0da069b5d76db
