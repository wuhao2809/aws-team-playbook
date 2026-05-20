resource "aws_dynamodb_table" "posts" {
  name         = "${var.project}-posts"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }
}
