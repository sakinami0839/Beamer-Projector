#ifndef BEAMER_NATIVE_PDF_H
#define BEAMER_NATIVE_PDF_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct BPPDF BPPDF;
typedef int (*BPVisitAnnotation)(void *context, int page, const char *name, const char *payload);

BPPDF *bp_pdf_open(const uint8_t *bytes, size_t size, char **error);
void bp_pdf_close(BPPDF *pdf);
int bp_pdf_visit(BPPDF *pdf, void *context, BPVisitAnnotation visit, char **error);
int bp_pdf_remove(BPPDF *pdf, void *context, BPVisitAnnotation should_remove, char **error);
int bp_pdf_add(BPPDF *pdf, int page, const char *dictionary, const char *payload,
               const char *appearance, double width, double height, double opacity, char **error);
int bp_pdf_bytes(BPPDF *pdf, uint8_t **bytes, size_t *size, char **error);
void bp_free(void *pointer);

#ifdef __cplusplus
}
#endif

#endif
