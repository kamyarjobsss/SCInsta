#import <Foundation/Foundation.h>

unsigned IXPathHookFill(const char **names, void **replacements, unsigned capacity);
void IXPathHookPrepare(void);
BOOL IXPathHookProxyReady(void);
id IXPathHookProxyObject(void);
id IXPathHookProxyObjectOnPort(uint16_t port);
