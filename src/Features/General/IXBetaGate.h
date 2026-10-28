#ifndef IX_BETA_GATE_H
#define IX_BETA_GATE_H

/* 1 when this Objective-C class is the full-screen TestFlight beta update gate. */
int IXBetaBlockerClassName(const char *name);

/* 1 when a receipt file name is the TestFlight sandbox receipt. */
int IXBetaSandboxReceiptName(const char *lastComponent);

#endif
