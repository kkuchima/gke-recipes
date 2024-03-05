# Install Vegeta (Workstations/Ubuntu)
```bash
VEGETA_VERSION=$(curl -s "https://api.github.com/repos/tsenart/vegeta/releases/latest" | grep -Po '"tag_name": "v\K[0-9.]+')
curl -Lo vegeta.tar.gz "https://github.com/tsenart/vegeta/releases/latest/download/vegeta_${VEGETA_VERSION}_linux_amd64.tar.gz"

mkdir vegeta-temp
tar xf vegeta.tar.gz -C vegeta-temp

sudo mv vegeta-temp/vegeta /usr/local/bin
```

# Run load test
```bash
export IP_ADDR=<YOUR_IP>
echo "GET http://${IP_ADDR}" | vegeta attack -duration=100s -rate=50 | vegeta report
```