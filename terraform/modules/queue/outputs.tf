output "queue_arn" {
  description = "ARN of the inference queue."
  value       = aws_sqs_queue.inference.arn
}

output "queue_url" {
  description = "URL consumed by API producers and Worker consumers."
  value       = aws_sqs_queue.inference.id
}

output "dead_letter_queue_arn" {
  description = "ARN of the dead-letter queue used for alarms and redrive."
  value       = aws_sqs_queue.dead_letter.arn
}

output "dead_letter_queue_url" {
  description = "URL of the dead-letter queue."
  value       = aws_sqs_queue.dead_letter.id
}
