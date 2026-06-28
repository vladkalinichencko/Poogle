import json
import math
import re
import sys
import unicodedata

import fitz
import mlx.core as mx
from mlx_embeddings import generate, load
from mlx_lm import load as load_language_model


QWEN_MODEL = "mlx-community/Qwen3-Embedding-4B-4bit-DWQ"
RERANKER_MODEL = "mlx-community/Qwen3-Reranker-0.6B-4bit"
QWEN_DIMENSIONS = 256
CHUNK_TOKENS = 512
CHUNK_OVERLAP = 128
CHUNK_STRIDE = CHUNK_TOKENS - CHUNK_OVERLAP
QWEN_BATCH_SIZE = 16
RERANK_TOKENS = 640
RERANK_INSTRUCTION = (
    "Retrieve passages from scientific papers that directly address the query. "
    "A passage is relevant when it explains the requested topic, method, "
    "result, mathematical apparatus, or evidence. Reject merely related words."
)
RERANK_PREFIX = (
    "<|im_start|>system\n"
    "Judge whether the Document meets the requirements based on the Query and "
    'the Instruct provided. The answer can only be "yes" or "no".'
    "<|im_end|>\n<|im_start|>user\n"
)
RERANK_SUFFIX = (
    "<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
)

fitz.TOOLS.mupdf_display_errors(False)
fitz.TOOLS.mupdf_display_warnings(False)


class Models:
    def __init__(self):
        self.qwen, self.qwen_tokenizer = load(QWEN_MODEL)
        self.reranker = None
        self.reranker_tokenizer = None

    def embed_file(self, request):
        document = extract_pdf(request["path"])
        chunks = [
            chunk
            for chunk in self.chunk_text(document["body"])
            if not is_degenerate(chunk["text"])
        ]
        return {
            "title": document["title"],
            "abstract": document["abstract"],
            "chunks": [
                chunk | {"embedding": embedding}
                for chunk, embedding in zip(
                    chunks,
                    self.embed_qwen([chunk["text"] for chunk in chunks]),
                )
            ],
        }

    def embed_query(self, request):
        query = request["query"]
        instructed = (
            "Instruct: Retrieve passages from scientific papers that answer "
            "the query.\nQuery: " + query
        )
        return {
            "body_embedding": self.embed_qwen([instructed])[0],
        }

    def rerank_documents(self, request):
        self.load_reranker()
        tokenizer = getattr(
            self.reranker_tokenizer,
            "_tokenizer",
            self.reranker_tokenizer,
        )
        prefix = tokenizer.encode(
            RERANK_PREFIX,
            add_special_tokens=False,
        )
        suffix = tokenizer.encode(
            RERANK_SUFFIX,
            add_special_tokens=False,
        )
        yes = tokenizer.convert_tokens_to_ids("yes")
        no = tokenizer.convert_tokens_to_ids("no")
        scores = []

        for document in request["documents"]:
            content = (
                f"<Instruct>: {RERANK_INSTRUCTION}\n"
                f"<Query>: {request['query']}\n"
                f"<Document title>: {document['title']}\n"
                f"<Document abstract>: {document['abstract']}\n"
                f"<Document passage>: {document['passage']}"
            )
            available = RERANK_TOKENS - len(prefix) - len(suffix)
            tokens = tokenizer.encode(
                content,
                add_special_tokens=False,
            )[:available]
            logits = self.reranker(
                mx.array([prefix + tokens + suffix])
            )[:, -1, :]
            pair = mx.stack([logits[0, no], logits[0, yes]])
            score = mx.softmax(pair)[1]
            mx.eval(score)
            scores.append(float(score))

        return {"scores": scores}

    def load_reranker(self):
        if self.reranker is None:
            self.reranker, self.reranker_tokenizer = load_language_model(
                RERANKER_MODEL
            )

    def chunk_text(self, text):
        chunks = []
        token_ids = self.qwen_tokenizer.encode(
            text,
            add_special_tokens=False,
        )
        for offset in range(0, len(token_ids), CHUNK_STRIDE):
            chunk = self.qwen_tokenizer.decode(
                token_ids[offset : offset + CHUNK_TOKENS],
                skip_special_tokens=True,
            ).strip()
            if chunk:
                chunks.append(
                    {
                        "heading": "Body",
                        "text": chunk,
                    }
                )
            if offset + CHUNK_TOKENS >= len(token_ids):
                break
        return chunks

    def embed_qwen(self, texts):
        if not texts:
            return []
        batches = []
        for offset in range(0, len(texts), QWEN_BATCH_SIZE):
            output = generate(
                self.qwen,
                self.qwen_tokenizer,
                texts=texts[offset : offset + QWEN_BATCH_SIZE],
                max_length=CHUNK_TOKENS,
            )
            embeddings = output.text_embeds
            embeddings = embeddings[:, :QWEN_DIMENSIONS]
            norms = mx.linalg.norm(
                embeddings,
                axis=1,
                keepdims=True,
            )
            embeddings = embeddings / mx.maximum(norms, 1e-12)
            mx.eval(embeddings)
            values = embeddings.tolist()
            if not all(
                math.isfinite(value)
                for embedding in values
                for value in embedding
            ):
                raise ValueError("Qwen produced a non-finite embedding")
            batches.extend(values)
        return batches


def main():
    models = Models()
    for line in sys.stdin:
        request = None
        try:
            request = json.loads(line)
            if request["operation"] == "embed_file":
                result = models.embed_file(request)
            elif request["operation"] == "embed_query":
                result = models.embed_query(request)
            elif request["operation"] == "rerank":
                result = models.rerank_documents(request)
            else:
                raise ValueError("unknown operation")
            response = {"result": result}
        except Exception as error:
            response = {
                "error": str(error),
            }
        print(json.dumps(response, allow_nan=False), flush=True)


def canonical_margin(text):
    text = re.sub(r"\s+", " ", text).strip().casefold()
    text = re.sub(r"^\d+\s+|\s+\d+$", "", text)
    return text


def is_degenerate(text):
    # A chunk that is mostly numbers, symbols, or tiny fragments — a flattened
    # table or number grid whose embedding is unreliable. Dropped before
    # embedding so it never enters the index. Byte-level over a bounded prefix
    # because such chunks are uniform.
    data = text.encode("utf-8")[:600]
    total = len(data)
    if total < 20:
        return True
    letters = sum(1 for b in data if 0x41 <= b <= 0x5A or 0x61 <= b <= 0x7A)
    digits = sum(1 for b in data if 0x30 <= b <= 0x39)
    return letters / total < 0.45 or digits / total > 0.30


def normalized_block(text):
    text = unicodedata.normalize("NFKC", text)
    text = text.replace("\u00ad", "")
    text = re.sub(
        r"(?<=\w)-[ \t]*\n[ \t]*(?=\w)",
        "",
        text,
    )
    return re.sub(r"\s+", " ", text).strip()


def file_title(path):
    name = path.rsplit("/", 1)[-1].rsplit(".", 1)[0]
    return normalized_block(name.replace("_", " "))


def title_noise_score(text):
    if not text:
        return 1.0
    compact = re.sub(r"\s+", "", text)
    tokens = re.findall(r"[A-Za-z][A-Za-z0-9\-]*", text)
    short_acronyms = [
        token
        for token in tokens
        if len(token) <= 6 and token.upper() == token
    ]
    punctuation = sum(
        1
        for character in text
        if not character.isalnum() and not character.isspace()
    )
    noise = 0.0

    if re.fullmatch(r"[A-Z0-9]{1,8}(?:-[A-Z0-9]{1,8})+", compact):
        noise += 0.75
    if re.match(
        r"(?i)^(?:https?://|www\.|published as\b|under review\b|"
        r"preprint\b|technical report\b|\*?ongoing work\b|"
        r"work in progress\b|accepted at\b|arxiv:)",
        text,
    ):
        noise += 1.0
    if re.fullmatch(r"(?i)research articles?", text):
        noise += 1.0
    if text[:1].islower() and text.endswith("."):
        noise += 0.65
    if len(re.findall(r"[\u00c0-\u00ff]", text)) >= 5:
        noise += 1.0
    if re.fullmatch(r"[\d\s.,;:()\-–—]+", text):
        noise += 1.0
    if re.search(r"(?i)\b(?:a|an|the|of|for|with|and|as|to)\s*$", text):
        noise += 0.65
    if len(text) > 180:
        noise += 0.35
    if len(tokens) <= 2:
        noise += 0.35
    if tokens and len(short_acronyms) / len(tokens) > 0.65:
        noise += 0.70
    if compact and punctuation / len(compact) > 0.25:
        noise += 0.35
    if re.search(
        r"(?i)\b(university|institute|department|school|laboratory|"
        r"microsoft|google|apple|stanford|berkeley|@|\.edu|\.com)\b",
        text,
    ):
        noise += 0.45
    if text.count(",") >= 5:
        noise += 0.30
    return min(noise, 1.0)


def clean_title_candidate(text):
    text = normalized_block(text)
    text = re.sub(r"(?i)\s+\babstract\b.*$", "", text).strip()
    affiliation = re.search(
        r"(?i)\b(university|institute|department|school|laboratory|"
        r"microsoft|google|apple|stanford|berkeley|@|\.edu|\.com)\b",
        text,
    )
    if affiliation and affiliation.start() > 24:
        text = text[: affiliation.start()].strip(" ,;:-")
    return text


def choose_title(candidates, fallback):
    fallback = clean_title_candidate(fallback)
    fallback_key = fallback.casefold()
    for candidate in candidates:
        raw_candidate = normalized_block(candidate)
        title = clean_title_candidate(candidate)
        title_key = title.casefold()
        if (
            fallback
            and fallback_key in title_key
            and (
                title.count(",") >= 5
                or re.search(
                    r"(?i)\b(university|institute|department|school|"
                    r"laboratory|microsoft|google|apple|stanford|"
                    r"berkeley|@|\.edu|\.com)\b",
                    raw_candidate,
                )
            )
            and title_noise_score(fallback) < 0.65
        ):
            return fallback
        if len(title) >= 8 and title_noise_score(title) < 0.65:
            return title
    return fallback


def should_repair_title(old_title, new_title):
    if old_title == new_title or title_noise_score(new_title) >= 0.65:
        return False
    old_key = re.sub(r"\s+", " ", old_title).strip().casefold()
    new_key = re.sub(r"\s+", " ", new_title).strip().casefold()
    # Refuse a replacement that only truncates the existing title to a prefix.
    if old_key.startswith(new_key) and len(new_key) < len(old_key):
        return False
    explicit_contamination = (
        len(old_title) > 180
        or re.search(r"(?i)\babstract\s*$", old_title)
        or re.search(
            r"(?i)\b(university|institute|department|school|laboratory|"
            r"microsoft|google|apple|stanford|berkeley|@|\.edu|\.com)\b",
            old_title,
        )
        # Title truncated to a dangling subtitle, e.g. ": Integrating ...".
        or bool(re.match(r"^\s*[:;,.–—-]", old_title))
        # Compatibility ligatures the original extraction left in place.
        or bool(re.search(r"[ﬀ-ﬆ]", old_title))
        # Filename or template placeholders that leaked in as the title.
        or bool(re.search(r"(?i)\.(dvi|tex|pdf)$", old_title))
        or bool(
            re.fullmatch(
                r"(?i)\s*(untitled|overleaf example|microsoft word.*|"
                r".*\bmanuscript\b.*|paper\d*|main|template)\s*",
                old_title,
            )
        )
    )
    return title_noise_score(old_title) >= 0.65 or bool(
        explicit_contamination
    )


def block_font_sizes(page):
    sizes = []
    for block in page.get_text("dict").get("blocks", []):
        spans = [
            span.get("size", 0)
            for line in block.get("lines", [])
            for span in line.get("spans", [])
            if span.get("text", "").strip()
        ]
        if spans:
            sizes.append((block["bbox"][1], max(spans)))
    return sizes


def font_size_at(y0, font_sizes):
    best_size = 0.0
    best_distance = float("inf")
    for y, size in font_sizes:
        distance = abs(y - y0)
        if distance < best_distance:
            best_distance = distance
            best_size = size
    return best_size


def block_title(document):
    page = document[0]
    height = page.rect.height
    font_sizes = block_font_sizes(page)
    rows = []
    for block in page.get_text("blocks", sort=False):
        _, y0, _, _, text, _, block_type = block
        if block_type != 0:
            continue
        clean = normalized_block(text)
        if not clean or clean.lower().startswith("arxiv:"):
            continue
        rows.append({"y0": y0, "text": clean, "size": font_size_at(y0, font_sizes)})

    top = [row for row in rows if row["y0"] < height * 0.45]
    if not top:
        return ""
    title_size = max(row["size"] for row in top)
    chosen = [
        row
        for row in sorted(top, key=lambda row: row["y0"])
        if row["size"] >= title_size * 0.93
    ]
    return normalized_block(" ".join(row["text"] for row in chosen))


def inferred_title(document, pages, path):
    candidates = []
    metadata = normalized_block((document.metadata or {}).get("title", ""))
    if len(metadata) > 4:
        candidates.append(metadata)

    visual = block_title(document)
    if len(visual) > 4:
        candidates.append(visual)

    for block in pages[0]:
        text = normalized_block(block["text"])
        if 8 <= len(text) <= 240 and not text.lower().startswith("arxiv:"):
            candidates.append(text)
            break
    return choose_title(candidates, file_title(path))


def extract_title(path):
    document = fitz.open(path)
    if document.page_count == 0:
        return file_title(path)
    blocks = []
    for block in document[0].get_text("blocks", sort=False):
        _, _, _, _, text, _, block_type = block
        if block_type == 0:
            blocks.append({"text": text, "margin": False})
    return inferred_title(document, [blocks], path)


ABSTRACT_END = re.compile(
    r"(?i)\b(?:1[\s.]*)?introduction\b"
    r"|\bkeywords?\b"
    r"|\bindex terms\b"
    r"|\bccs concepts\b"
    r"|\bgeneral terms\b"
    r"|\bcategories and subject descriptors\b"
)


def is_abstract_like(text):
    if not 120 <= len(text) <= 3500:
        return False
    if re.match(r"(?i)^(figure|fig\.?|table|algorithm|equation)\b", text):
        return False
    # Superscript-numbered institution lists, e.g. "1FAIR 2New York University".
    if len(re.findall(r"\b\d+[A-Z][a-zA-Z]", text)) >= 2:
        return False
    words = re.findall(r"[A-Za-z]{2,}", text)
    if len(words) < 20:
        return False
    if len(words) / max(len(text.split()), 1) < 0.60:
        return False
    if text.count(",") / len(words) > 0.35:
        return False
    if re.search(r"@|\.edu\b|\.com\b|https?://", text):
        return False
    return True


def abstract_from(text, page_blocks):
    head = text[:8000]
    match = re.search(r"(?is)\babstract\b[\s:.—\-]*", head)
    if match:
        rest = head[match.end():]
        stop = ABSTRACT_END.search(rest)
        if stop:
            candidate = normalized_block(rest[: stop.start()])
            if is_abstract_like(candidate):
                return candidate[:3000]
    for block in page_blocks:
        candidate = normalized_block(block["text"])
        if ABSTRACT_END.search(candidate):
            break
        if candidate.lower().startswith("abstract"):
            candidate = normalized_block(candidate[len("abstract"):])
        if is_abstract_like(candidate):
            return candidate[:3000]
    return ""


def extract_abstract(path):
    return extract_pdf(path)["abstract"]


def extract_pdf(path):
    document = fitz.open(path)
    pages = []
    margin_counts = {}

    for page in document:
        blocks = []
        for block in page.get_text("blocks", sort=False):
            x0, y0, x1, y1, text, _, block_type = block
            if block_type != 0:
                continue
            is_margin = (
                y1 <= page.rect.height * 0.08
                or y0 >= page.rect.height * 0.92
            )
            row = {"text": text, "margin": is_margin}
            blocks.append(row)
            if is_margin:
                canonical = canonical_margin(text)
                if canonical:
                    margin_counts[canonical] = margin_counts.get(canonical, 0) + 1
        pages.append(blocks)

    threshold = max(3, math.ceil(len(pages) * 0.2))
    repeated_margins = {
        text
        for text, count in margin_counts.items()
        if count >= threshold
    }
    body_blocks = []
    for page in pages:
        for block in page:
            canonical = canonical_margin(block["text"])
            digits = re.sub(r"\s+", "", block["text"])
            if block["margin"] and (
                canonical in repeated_margins
                or digits.isdigit()
            ):
                continue
            text = normalized_block(block["text"])
            if text:
                body_blocks.append(text)

    text = " ".join(body_blocks)
    title = inferred_title(document, pages, path)
    abstract = abstract_from(text, pages[0])
    introduction = re.search(
        r"(?i)\b(?:1[.\s]+)?introduction\b",
        text,
    )
    body = text[introduction.start():] if introduction else text
    return {
        "title": title,
        "abstract": abstract,
        "body": body,
    }


if __name__ == "__main__":
    main()
