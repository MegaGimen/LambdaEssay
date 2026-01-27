from __future__ import annotations

MCP_TOOL_CATALOG = {
    "document_management": [
        "create_document",
        "get_document_info",
        "get_document_text",
        "get_document_outline",
        "list_available_documents",
        "copy_document",
        "convert_to_pdf",
    ],
    "content_creation": [
        "add_heading",
        "add_paragraph",
        "add_table",
        "add_picture",
        "add_page_break",
        "insert_header_near_text",
        "insert_line_or_paragraph_near_text",
        "insert_numbered_list_near_text",
    ],
    "formatting": [
        "format_text",
        "search_and_replace",
        "delete_paragraph",
        "create_custom_style",
        "format_table",
        "set_table_cell_shading",
        "apply_table_alternating_rows",
        "highlight_table_header",
        "merge_table_cells",
        "merge_table_cells_horizontal",
        "merge_table_cells_vertical",
        "set_table_cell_alignment",
        "set_table_alignment_all",
        "format_table_cell_text",
        "set_table_cell_padding",
        "set_table_column_width",
        "set_table_column_widths",
        "set_table_width",
        "auto_fit_table_columns",
    ],
    "footnotes_endnotes": [
        "add_footnote_to_document",
        "add_footnote_after_text",
        "add_footnote_before_text",
        "add_footnote_enhanced",
        "add_endnote_to_document",
        "customize_footnote_style",
        "delete_footnote_from_document",
        "add_footnote_robust",
        "validate_document_footnotes",
        "delete_footnote_robust",
    ],
    "comments": [
        "get_all_comments",
        "get_comments_by_author",
        "get_comments_for_paragraph",
    ],
    "text_lookup": [
        "get_paragraph_text_from_document",
        "find_text_in_document",
    ],
}


def list_mcp_capabilities() -> dict:
    return MCP_TOOL_CATALOG.copy()
