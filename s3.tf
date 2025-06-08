
provider "aws" {
  alias  = "replica"
  region = "us-west-2" # destination region
}

# ===== DATA SOURCES =====

data "aws_iam_policy_document" "kms_policy" {
  statement {
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }
}

# ===== KMS KEY =====
resource "aws_kms_key" "s3_key" {
  description         = "KMS key for S3 encryption"
  enable_key_rotation = true
  policy              = data.aws_iam_policy_document.kms_policy.json
}

# ===== SOURCE BUCKET (us-east-1) =====
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

    filter {}  # this applies to all objects

    expiration {
      days = 365
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# ===== DESTINATION BUCKET (us-west-2) =====
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

# ===== IAM ROLE FOR REPLICATION =====
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

# ===== REPLICATION CONFIGURATION =====
resource "aws_s3_bucket_replication_configuration" "replication" {
  bucket = aws_s3_bucket.s3_tf.id
  role   = aws_iam_role.replication.arn

  rule {
    id     = "replication-rule"
    status = "Enabled"

    filter {
      prefix = "" # replicate all
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
