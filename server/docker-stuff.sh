docker build -t ms-copilot-maf .

docker stop ms-copilot-maf
docker rm ms-copilot-maf

docker run -d -p 3978:3978 --env-file .env --name ms-copilot-maf ms-copilot-maf
docker logs -f ms-copilot-maf