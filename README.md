Repo that contains nginx proxy docker container and utils to run shared network for multiple docker containers (proxy, backend (db, headless browser, api), frontend)...





// renew SSL certificates (or run for the first time)::::::::::::::::

// the command needs to be executed for each domain/subdomain separately! 



cd /var/www/proxy



docker compose run --rm -p 80:80 certbot certonly --standalone --agree-tos --no-eff-email --email mehmedovic.seid@gmail.com -d codeeve.com



docker compose run --rm -p 80:80 certbot certonly --standalone --agree-tos --no-eff-email --email mehmedovic.seid@gmail.com -d scout.codeeve.com



docker compose run --rm -p 80:80 certbot certonly --standalone --agree-tos --no-eff-email --email mehmedovic.seid@gmail.com -d flxng.codeeve.com



docker compose run --rm -p 80:80 certbot certonly --standalone --agree-tos --no-eff-email --email mehmedovic.seid@gmail.com -d piker.codeeve.com



docker compose run --rm -p 80:80 certbot certonly --standalone --agree-tos --no-eff-email --email mehmedovic.seid@gmail.com -d emo.codeeve.com









docker exec nginx-proxy nginx -s reload









atm the structure looks like this:



/var/www/

&nbsp;	 proxy/

&nbsp;		docker-compose.yml

&nbsp;		renew-certbot.sh

&nbsp;		nginx/

&nbsp;			nginx.conf

&nbsp;	common/

&nbsp;		docker-start-apps.sh

&nbsp;	scout/

&nbsp;	        Piker.API/

&nbsp;		Piker.Web/

&nbsp;		eMo.API/	

&nbsp;		eMo.Data/

&nbsp;		eMo.Ext

&nbsp;	flxng/

&nbsp;	        ... flxng repo // deprecated



docker-compose.yml and Dockerfile files for scout and flxng repos are within the repo root directory!







