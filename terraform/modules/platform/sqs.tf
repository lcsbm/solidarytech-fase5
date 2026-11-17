# Dead Letter Queue: mensagens de doacao que falham 3x vao para ca em vez de
# serem perdidas. E um requisito de confiabilidade do Hot Path (donation-service).
resource "aws_sqs_queue" "donations_dlq" {
  name = "${local.name_prefix}-donations-dlq"

  message_retention_seconds = 1209600 # 14 dias
  sqs_managed_sse_enabled   = true

  tags = merge(local.common_tags, {
    Name    = "${local.name_prefix}-donations-dlq"
    Service = "donation-service"
  })
}

resource "aws_sqs_queue" "donations" {
  name = "${local.name_prefix}-donations"

  message_retention_seconds  = 345600 # 4 dias
  visibility_timeout_seconds = 60
  sqs_managed_sse_enabled    = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.donations_dlq.arn
    maxReceiveCount     = 3
  })

  tags = merge(local.common_tags, {
    Name    = "${local.name_prefix}-donations"
    Service = "donation-service"
  })
}
