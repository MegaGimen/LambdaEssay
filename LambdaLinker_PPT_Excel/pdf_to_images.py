from __future__ import annotations

from pathlib import Path
from typing import Iterable, Optional

def render_pdf_pages_to_png(
    pdf_path: str,
    *,
    page_indices_1based: Optional[Iterable[int]] = None,
    out_dir: str = ".cache_pdf_images",
    dpi: int = 160,
) -> list[str]:
    """
    用 PyMuPDF(fitz) 把 PDF 的指定页渲染成 PNG。
    page_indices_1based：例如 [1,2,5] 表示第 1/2/5 页。
    """
    try:
        import fitz  # PyMuPDF
    except Exception as exc:  # pragma: no cover
        raise RuntimeError("需要安装 pymupdf：pip install pymupdf") from exc

    out = Path(out_dir).resolve()
    out.mkdir(parents=True, exist_ok=True)

    doc = fitz.open(pdf_path)
    n = doc.page_count

    if page_indices_1based is None:
        pages = list(range(1, n + 1))
    else:
        pages = [p for p in page_indices_1based if 1 <= int(p) <= n]

    zoom = dpi / 72.0
    mat = fitz.Matrix(zoom, zoom)

    outputs: list[str] = []
    for p in pages:
        page = doc.load_page(p - 1)
        pix = page.get_pixmap(matrix=mat, alpha=False)
        img_path = out / f"{Path(pdf_path).stem}_p{p}.png"
        pix.save(str(img_path))
        outputs.append(str(img_path))

    doc.close()
    return outputs
