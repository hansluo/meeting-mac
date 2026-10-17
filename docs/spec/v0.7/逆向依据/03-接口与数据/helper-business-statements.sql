-- Exact extracted SQL strings. No observed database has been opened.
CREATE TABLE IF NOT EXISTS documents (id TEXT PRIMARY KEY, content TEXT, userId TEXT, maxTokensPerChunk INTEGER, chunkOverlap INTEGER, mimeType TEXT, imageBytes BLOB);
-- Helper file offset 0x3135af8
CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT);
-- Helper file offset 0x3135ba0
INSERT OR REPLACE INTO documents (id, content, userId, maxTokensPerChunk, chunkOverlap, mimeType, imageBytes) VALUES (?, ?, ?, ?, ?, ?, ?);
-- Helper file offset 0x3135be8
SELECT content, userId, maxTokensPerChunk, chunkOverlap, mimeType, imageBytes FROM documents WHERE id = ?;
-- Helper file offset 0x3135c74
DELETE FROM documents WHERE id = ?;
-- Helper file offset 0x3135cdf
SELECT id, content, userId, maxTokensPerChunk, chunkOverlap, mimeType, imageBytes FROM documents;
-- Helper file offset 0x3135d03
SELECT value FROM settings WHERE key = ?;
-- Helper file offset 0x3135d65
INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?);
-- Helper file offset 0x3135d8f
SELECT node_id, vector_cos_similarity(vector_read_blob(embedding), vector_write_blob(?)) as similarity FROM node_embeddings ORDER BY similarity DESC LIMIT 1
-- Helper file offset 0x3784c7e
SELECT *, vector_cos_similarity(vector_read_blob($1), @query_embeddings) AS temp_similarity_score FROM $0 WHERE temp_similarity_score >= $2 AND ($4 IS NULL OR $4 >= strftime('%s', 'now')) $5 ORDER BY temp_similarity_score DESC LIMIT $3
-- Helper file offset 0x37a044a
SELECT *, vector_cos_similarity(vector_read_blob($1), @query_embeddings) AS temp_similarity_score FROM $0 WHERE ($4 IS NULL OR $4 >= strftime('%s', 'now')) $5 ORDER BY temp_similarity_score DESC LIMIT $3
-- Helper file offset 0x37a0536
WITH TopMatches AS (  SELECT rowid, vector_cos_similarity(vector_read_blob($1), @query_embeddings)   AS temp_similarity_score FROM $0   WHERE temp_similarity_score >= $2   ORDER BY temp_similarity_score DESC   LIMIT $3) SELECT t.*, m.temp_similarity_score FROM $0 t JOIN TopMatches m ON t.rowid = m.rowid ORDER BY m.temp_similarity_score DESC
-- Helper file offset 0x37a8aac
PRAGMA journal_mode=WAL;
-- Helper file offset 0x37a8c9b
PRAGMA synchronous=NORMAL;
-- Helper file offset 0x37a8cb4
BEGIN TRANSACTION;
-- Helper file offset 0x37a8d88
ROLLBACK;
-- Helper file offset 0x37a8d9b
COMMIT;
-- Helper file offset 0x37a8da5