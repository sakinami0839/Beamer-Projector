#include "NativePDF.h"
#include <qpdf/Buffer.hh>
#include <qpdf/QPDF.hh>
#include <qpdf/QPDFPageDocumentHelper.hh>
#include <qpdf/QPDFWriter.hh>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

struct BPPDF {
    std::string input;
    QPDF document;
    std::vector<QPDFPageObjectHelper> pages;
};

namespace {
constexpr char payload_key[] = "/BeamerProjectorV1";

template <typename Operation>
int attempt(char **error, Operation operation)
{
    try {
        operation();
        return 1;
    } catch (const std::exception &exception) {
        if (error) {
            *error = strdup(exception.what());
        }
        return 0;
    }
}

void visit_annotations(BPPDF &pdf, void *context, BPVisitAnnotation visit, bool remove)
{
    for (size_t i = 0; i < pdf.pages.size(); ++i) {
        auto page = pdf.pages[i].getObjectHandle();
        auto annots = page.getKey("/Annots");
        if (!annots.isArray()) {
            continue;
        }
        std::vector<QPDFObjectHandle> kept;
        bool changed = false;
        for (auto annotation : annots.aitems()) {
            auto name = annotation.getKey("/NM");
            auto payload = annotation.getKey(payload_key);
            if (name.isString() && payload.isString()) {
                bool selected = visit(context, static_cast<int>(i),
                                      name.getStringValue().c_str(), payload.getStringValue().c_str());
                if (remove && selected) {
                    changed = true;
                    continue;
                }
            }
            if (remove) {
                kept.push_back(annotation);
            }
        }
        if (changed) {
            page.replaceKey("/Annots", QPDFObjectHandle::newArray(kept));
        }
    }
}
}

BPPDF *bp_pdf_open(const uint8_t *bytes, size_t size, char **error)
{
    std::unique_ptr<BPPDF> pdf;
    if (!attempt(error, [&] {
        pdf = std::make_unique<BPPDF>();
        pdf->input.assign(reinterpret_cast<const char *>(bytes), size);
        pdf->document.processMemoryFile("PDF", pdf->input.data(), pdf->input.size());
        pdf->pages = QPDFPageDocumentHelper(pdf->document).getAllPages();
    })) {
        return nullptr;
    }
    return pdf.release();
}

void bp_pdf_close(BPPDF *pdf)
{
    delete pdf;
}

int bp_pdf_visit(BPPDF *pdf, void *context, BPVisitAnnotation visit, char **error)
{
    return attempt(error, [&] { visit_annotations(*pdf, context, visit, false); });
}

int bp_pdf_remove(BPPDF *pdf, void *context, BPVisitAnnotation should_remove, char **error)
{
    return attempt(error, [&] { visit_annotations(*pdf, context, should_remove, true); });
}

int bp_pdf_add(BPPDF *pdf, int page_index, const char *dictionary, const char *payload,
               const char *appearance, double width, double height, double opacity, char **error)
{
    return attempt(error, [&] {
        using Object = QPDFObjectHandle;
        auto page = pdf->pages.at(page_index).getObjectHandle();
        auto mark = Object::parse(dictionary);
        mark.replaceKey("/P", page);
        mark.replaceKey(payload_key, Object::newString(payload));
        auto form = pdf->document.newStream(std::string(appearance));
        auto form_dict = form.getDict();
        form_dict.replaceKey("/Type", Object::newName("/XObject"));
        form_dict.replaceKey("/Subtype", Object::newName("/Form"));
        form_dict.replaceKey("/BBox", Object::newArray(Object::Rectangle{0, 0, width, height}));
        auto alpha = Object::newReal(opacity, 6);
        auto graphics = Object::newDictionary({{"/ca", alpha}, {"/CA", alpha}});
        auto states = Object::newDictionary({{"/InkOpacity", graphics}});
        form_dict.replaceKey("/Resources", Object::newDictionary({{"/ExtGState", states}}));
        mark.replaceKey("/AP", Object::newDictionary({{"/N", form}}));
        auto original = page.getKey("/Annots");
        auto annotations = original.isArray() ? original.getArrayAsVector() : std::vector<Object>{};
        annotations.push_back(pdf->document.makeIndirectObject(mark));
        page.replaceKey("/Annots", Object::newArray(annotations));
    });
}

int bp_pdf_bytes(BPPDF *pdf, uint8_t **bytes, size_t *size, char **error)
{
    return attempt(error, [&] {
        QPDFWriter writer(pdf->document);
        writer.setOutputMemory();
        writer.write();
        auto buffer = writer.getBufferSharedPointer();
        auto copy = static_cast<uint8_t *>(malloc(buffer->getSize()));
        if (!copy) {
            throw std::bad_alloc();
        }
        std::memcpy(copy, buffer->getBuffer(), buffer->getSize());
        *bytes = copy;
        *size = buffer->getSize();
    });
}

void bp_free(void *pointer)
{
    std::free(pointer);
}
