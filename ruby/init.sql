ALTER TABLE memos ADD title text;
UPDATE memos SET title = SUBSTRING_INDEX(content, "\n", 1);
CREATE INDEX memos_on_is_private_created_at ON memos(is_private, created_at);
CREATE INDEX memos_on_user_created_at ON memos(user, created_at);
