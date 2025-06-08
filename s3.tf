provider "aws" {
  alias  = "replica"
  region = "us-west-2"
}

# --- KMS Key with Inline Policy to Avoid Circular Dependency ---
resource "aws_kms_key" "s3_key" {
  description         = "KMS key for S3 encryption"
  enable_key_rotation = true

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        },
        Action   = "kms:*",
        Resource = "*"
      }
    ]
  })
}

# --- SOURCE BUCKET (us-east-1) ---
resource "aws_s3_bucket" "s3_tf" {
  bucket = format("%s-s3-tf-bkt-%s", local.name_prefix, local.account_id)
}

resource "aws_s3_bucket_versioning" "s3_tf" {
  bucket = aws_s3_bucket.s3_tf.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_logging" "s3_tf" {
  bucket        = aws_s3_bucket.s3_tf.id
  target_bucket = "nabilah-logging-bucket"
  target_prefix = "log/"
}

resource "aws_s3_bucket_public_access_block" "s3_tf" {
  bucket                  = aws_s3_bucket.s3_tf.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "s3_tf" {
  bucket = aws_s3_bucket.s3_tf.id

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.s3_key.arn
      sse_algorithm     = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "s3_tf" {
  bucket = aws_s3_bucket.s3_tf.id

  rule {
    id     = "expire-old-objects"
    status = "Enabled"

    expiration {
      days = 365
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }

    filter {} # Required since prefix is deprecated
  }
}

resource "aws_s3_bucket_notification" "bucket_notification" {
  bucket = aws_s3_bucket.s3_tf.id
}
# --- DESTINATION BUCKET (us-west-2) ---
resource "aws_s3_bucket" "replication_dest" {
  provider = aws.replica
  bucket   = "nabilah-s3-replication-dest"
}

resource "aws_s3_bucket_versioning" "replication_dest" {
  provider = aws.replica
  bucket   = aws_s3_bucket.replication_dest.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "replication_dest" {
  provider                = aws.replica
  bucket                  = aws_s3_bucket.replication_dest.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "replication_dest" {
  provider = aws.replica
  bucket   = aws_s3_bucket.replication_dest.id

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.s3_key.arn
      sse_algorithm     = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "replication_dest" {
  provider = aws.replica
  bucket   = aws_s3_bucket.replication_dest.id

  rule {
    id     = "expire-replicated-objects"
    status = "Enabled"

    expiration {
      days = 365
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }

    filter {}
  }
}

resource "aws_s3_bucket_logging" "replication_dest" {
  provider      = aws.replica
  bucket        = aws_s3_bucket.replication_dest.id
  target_bucket = "nabilah-logging-bucket"
  target_prefix = "replica-log/"
}

# --- REPLICATION ROLE AND POLICY ---
resource "aws_iam_role" "replication" {
  name = "s3-replication-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = {
        Service = "s3.amazonaws.com"
      },
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "replication_policy" {
  name = "s3-replication-policy"
  role = aws_iam_role.replication.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "s3:GetReplicationConfiguration",
          "s3:ListBucket"
        ],
        Resource = [
          aws_s3_bucket.s3_tf.arn
        ]
      },
      {
        Effect = "Allow",
        Action = [
          "s3:GetObjectVersion",
          "s3:GetObjectVersionAcl",
          "s3:ReplicateObject",
          "s3:ReplicateDelete",
          "s3:ReplicateTags"
        ],
        Resource = [
          "${aws_s3_bucket.s3_tf.arn}/*"
        ]
      },
      {
        Effect = "Allow",
        Action = [
          "s3:ReplicateObject"
        ],
        Resource = [
          "${aws_s3_bucket.replication_dest.arn}/*"
        ]
      }
    ]
  })
}

# --- REPLICATION CONFIGURATION ---
resource "aws_s3_bucket_replication_configuration" "replication" {
  bucket = aws_s3_bucket.s3_tf.id
  role   = aws_iam_role.replication.arn

  rule {
    id     = "replication-rule"
    status = "Enabled"

    filter {
      prefix = ""
    }

    destination {
      bucket        = aws_s3_bucket.replication_dest.arn
      storage_class = "STANDARD"
    }
  }

  depends_on = [
    aws_s3_bucket_versioning.s3_tf,
    aws_s3_bucket_versioning.replication_dest
  ]
}
resource "aws_sqs_queue" "s3_events" {
  name = "replication-dest-events"
}

resource "aws_s3_bucket_notification" "replication_dest_notify" {
  bucket = aws_s3_bucket.replication_dest.id

  queue {
    queue_arn     = aws_sqs_queue.s3_events.arn
    events        = ["s3:ObjectCreated:*"]
  }

  depends_on = [aws_sqs_queue.s3_events]
}
