COMPOSE_DIR := compose
ANSIBLE_DIR := ansible

.PHONY: bootstrap deploy destroy destroy-all redeploy status logs

bootstrap:
	@if [ -f $(COMPOSE_DIR)/.env ]; then \
		echo "$(COMPOSE_DIR)/.env already exists, skipping."; \
	else \
		cp $(COMPOSE_DIR)/.env.example $(COMPOSE_DIR)/.env; \
		echo "Created $(COMPOSE_DIR)/.env from template — edit it with real values before running 'make deploy'."; \
	fi
	@if [ -f $(COMPOSE_DIR)/mysqld_exporter.cnf ]; then \
		echo "$(COMPOSE_DIR)/mysqld_exporter.cnf already exists, skipping."; \
	else \
		cp $(COMPOSE_DIR)/mysqld_exporter.cnf.example $(COMPOSE_DIR)/mysqld_exporter.cnf; \
		echo "Created $(COMPOSE_DIR)/mysqld_exporter.cnf from template — edit it with the same exporter password used in .env."; \
	fi

deploy:
	ansible-playbook -i $(ANSIBLE_DIR)/inventory.ini $(ANSIBLE_DIR)/site.yml

destroy:
	cd $(COMPOSE_DIR) && docker compose down
	@echo "Containers and non-cert volumes preserved cert storage (caddy_data, caddy_config kept)."
	@echo "Use 'make destroy-all' to also wipe certificate storage (will trigger new Let's Encrypt issuance)."
	cd $(COMPOSE_DIR) && docker volume rm compose_db_data compose_redis_data compose_nc_data compose_prometheus_data compose_grafana_data compose_loki_data 2>/dev/null || true

destroy-all:
	cd $(COMPOSE_DIR) && docker compose down -v

redeploy: destroy deploy

status:
	cd $(COMPOSE_DIR) && docker compose ps

logs:
	cd $(COMPOSE_DIR) && docker compose logs -f
