COMPOSE_DIR := compose
ANSIBLE_DIR := ansible

.PHONY: deploy destroy redeploy status logs

deploy:
	ansible-playbook -i $(ANSIBLE_DIR)/inventory.ini $(ANSIBLE_DIR)/site.yml

destroy:
	cd $(COMPOSE_DIR) && docker compose down -v

redeploy: destroy deploy

status:
	cd $(COMPOSE_DIR) && docker compose ps

logs:
	cd $(COMPOSE_DIR) && docker compose logs -f
