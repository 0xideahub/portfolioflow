# PortfolioFlow Railway Deployment Guide

## Quick Deploy to Railway

### 1. Connect to Railway
1. Go to [railway.app](https://railway.app)
2. Sign up with GitHub
3. Click "New Project" → "Deploy from GitHub repo"
4. Select your PortfolioFlow repository

### 2. Add Services
Railway will auto-detect Rails and add:
- **Web Service** (your Rails app)
- **PostgreSQL Database** (auto-created)
- **Redis** (for Sidekiq)

### 3. Configure Environment Variables
Add these in Railway dashboard:

**Required:**
```
RAILS_MASTER_KEY=e832ed5289c81b7ea48716f4033ac674
RAILS_ENV=production
RAILS_SERVE_STATIC_FILES=true
RAILS_LOG_TO_STDOUT=true
```

**Optional (for full functionality):**
```
SELF_HOSTED=true
APP_DOMAIN=your-domain.com
```

### 4. Deploy
Railway will automatically:
- Build your Rails app
- Run database migrations
- Start the server
- Provide a public URL

### 5. Custom Domain (Optional)
1. Go to your Railway project
2. Click on your web service
3. Go to "Settings" → "Domains"
4. Add your custom domain
5. Update DNS records as instructed

## Local Testing
Test the deployment locally:
```bash
# Test production build
RAILS_ENV=production bundle exec rails assets:precompile
RAILS_ENV=production bundle exec rails db:migrate
```

## Troubleshooting

### Common Issues:
- **Branch Protection**: If PR merge is blocked, temporarily disable branch protection in Settings → Branches
- **Database Connection**: Ensure DATABASE_URL is set in Railway environment variables
- **Asset Compilation**: Check that RAILS_MASTER_KEY is set correctly
- **Procfile Issues**: Ensure Procfile exists and uses correct Rails server command

### Deployment Fixes Applied:
- ✅ Added `Procfile` with `web: bundle exec rails server -p $PORT -b 0.0.0.0`
- ✅ Fixed database.yml to handle Railway's DATABASE_URL
- ✅ Resolved linting issues (30+ RuboCop violations)
- ✅ Fixed test failures (branding, icon sizes)
- ✅ Updated all Maybe references to PortfolioFlow

## Cost
- **Free tier**: $5 credit/month (enough for MVP)
- **Scaling**: Pay as you grow 