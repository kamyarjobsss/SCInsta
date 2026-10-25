#ifndef IX_SESSION_SOURCE_H
#define IX_SESSION_SOURCE_H

#include <stddef.h>

/* Startup session sources. The sideload has no app-group entitlement, so
   these are the stores Instagram reads while restoring a user. The probe
   logs presence and size only. Cookie values, keychain blobs, and raw ids
   are not part of this format. */

#define IX_PATH_MISSING 0
#define IX_PATH_DOCUMENTS 1
#define IX_PATH_SYSTEM 2
#define IX_PATH_OTHER 3

/* group.com.burbn.instagram, group.com.facebook.family, group.com.burbn.family.
   NULL when index is out of range. */
const char *IXSessionGroupIdentifier(int index);

/* missing, documents, system, or other. A nil or empty path is missing.
   Documents wins when both Documents and a group-container fragment appear. */
int IXSessionPathClass(const char *path);
const char *IXSessionPathClassName(int klass);

/* One diagnostic line:
   source phase=<phase> kind=<kind> name=<name> present=<0|1> bytes=<n> detail=<detail>
   phase, kind, and name are limited tokens. "sessionid" and "password" are
   rejected so the launch log cannot carry them. Returns 0 when the line
   does not fit or a field is rejected. */
int IXSessionSourceLine(const char *phase, const char *kind, const char *name,
                        int present, unsigned long long bytes, const char *detail,
                        char *out, size_t outLen);

/* Log name for a cookie we are allowed to record as present or absent.
   sessionid becomes session_cookie. Anything else returns 0. */
int IXSessionCookieLogName(const char *cookie, char *out, size_t outLen);

/* 1 when a filename (not a path) is a session archive we may size.
   A slash or a run of 6 digits is rejected so a user id in the name is not logged. */
int IXSessionArchiveName(const char *name);

/* Fixed log name for an archive. The filename itself is not returned, so a
   username embedded in it cannot reach the launch log. */
int IXSessionArchiveLogName(const char *name, char *out, size_t outLen);

/* 1 for directory names the startup walk is allowed to enter. */
int IXSessionScanDirectory(const char *name);

/* Replace a run of 6 or more digits with a single '#'. */
int IXSessionRedactDigits(const char *text, char *out, size_t outLen);

/* Implemented in IXSessionSourceProbe.m. Host tests do not link these.
   Files and cookies only; no SecItem and no class walk. */
void IXSessionSourceProbeFiles(const char *phase);
/* Status and count only, via the Security export, not a rewritten slot. */
void IXSessionSourceProbeKeychain(const char *phase);

#endif
