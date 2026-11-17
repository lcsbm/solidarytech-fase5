resource "aws_dynamodb_table" "volunteers" {
  name = "SolidaryTechVolunteers-${lower(var.environment)}"

  # PAY_PER_REQUEST: sem capacidade provisionada ociosa — adequado ao trafego
  # imprevisivel da plataforma e ao orcamento restrito da ONG.
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "volunteer_id"

  attribute {
    name = "volunteer_id"
    type = "S"
  }

  # GSI para consultar voluntarios por ONG sem Scan completo.
  # O codigo atual usa Scan; o indice fica disponivel para a evolucao.
  attribute {
    name = "ngo_id"
    type = "N"
  }

  global_secondary_index {
    name            = "ngo_id-index"
    hash_key        = "ngo_id"
    projection_type = "ALL"
  }

  # PITR reduz o RPO desta base para ~5 minutos (vs. 24h dos snapshots RDS).
  point_in_time_recovery {
    enabled = var.dynamodb_enable_pitr
  }

  server_side_encryption {
    enabled = true
  }

  tags = merge(local.common_tags, {
    Name    = "SolidaryTechVolunteers-${lower(var.environment)}"
    Service = "volunteer-service"
  })
}
