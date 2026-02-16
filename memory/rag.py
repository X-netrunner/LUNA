import hashlib
import os
import sys

import chromadb
from chromadb.utils import embedding_functions

DEBUG = os.getenv("LUNA_DEBUG", "false").lower() == "true"  # gets it from luna.sh


def debug_print(*args):
    if DEBUG:
        print("[DEBUG]", *args, file=sys.stderr)


os.makedirs("memory/chroma_db", exist_ok=True)

embedding_function = None


def get_embedding_function():
    global embedding_function
    if embedding_function is None:
        debug_print("Loading embedding model...")
        embedding_function = embedding_functions.SentenceTransformerEmbeddingFunction(
            model_name="all-MiniLM-L6-v2"
        )
    return embedding_function


client = chromadb.PersistentClient(path="memory/chroma_db")

collection = None


def get_collection():
    global collection
    if collection is None:
        collection = client.get_or_create_collection(
            name="memory", embedding_function=get_embedding_function()
        )
    return collection


def add_entry(text):
    if not text.strip():
        return "__ERROR__ Empty memory."

    doc_id = hashlib.sha256(text.encode()).hexdigest()

    collection = get_collection()
    collection.upsert(documents=[text], ids=[doc_id])

    debug_print("Memory stored with ID:", doc_id)
    return "✓ Memory saved."


# change 0.8 to 0.5 if you get mismatches
def query(text, top_k=1, similarity_threshold=0.8):
    if not text.strip():
        return ""

    collection = get_collection()
    results = collection.query(
        query_texts=[text], n_results=top_k, include=["documents", "distances"]
    )

    docs = results.get("documents", [[]])[0]
    distances = results.get("distances", [[]])[0]

    if not docs:
        return ""

    relevant_docs = []

    for doc, dist in zip(docs, distances):
        if dist is not None and dist < similarity_threshold:
            relevant_docs.append(doc)

    if not relevant_docs:
        return ""

    # RETURN RAW MEMORY TEXT ONLY
    return "\n".join(relevant_docs)


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(0)

    mode = sys.argv[1]
    text = " ".join(sys.argv[2:])

    if mode == "add":
        print(add_entry(text))

    elif mode == "query":
        result = query(text)
        if result:
            print(result)
