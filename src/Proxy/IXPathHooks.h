#import <Foundation/Foundation.h>

unsigned IXPathHookFill(const char **names, void **replacements, unsigned capacity);
void IXPathHookPrepare(void);
/// Replacement for a Network.framework symbol resolved with dlsym, or NULL.
void *IXPathHookReplaceSymbol(const char *name);
BOOL IXPathHookProxyReady(void);
id IXPathHookProxyObject(void);
id IXPathHookProxyObjectOnPort(uint16_t port);
