const MIN_INDEXABLE_REVIEW_CHARS = 80;
const MIN_INDEXABLE_REVIEWS_FOR_POSTS_INDEX = 3;

function normalizedReviewLength(value) {
  const normalized = String(value || "").replace(/\s+/g, " ").trim();
  return Array.from(normalized).length;
}

function isIndexableReview(post) {
  return (
    post &&
    String(post.id || "").trim().length > 0 &&
    post.is_spoiler !== true &&
    normalizedReviewLength(post.comment) >= MIN_INDEXABLE_REVIEW_CHARS
  );
}

function indexableReviewCount(posts) {
  if (!Array.isArray(posts)) return 0;
  return posts.filter(isIndexableReview).length;
}

function isPostsIndexIndexable(posts) {
  return indexableReviewCount(posts) >= MIN_INDEXABLE_REVIEWS_FOR_POSTS_INDEX;
}

module.exports = {
  MIN_INDEXABLE_REVIEW_CHARS,
  MIN_INDEXABLE_REVIEWS_FOR_POSTS_INDEX,
  normalizedReviewLength,
  isIndexableReview,
  indexableReviewCount,
  isPostsIndexIndexable,
};
