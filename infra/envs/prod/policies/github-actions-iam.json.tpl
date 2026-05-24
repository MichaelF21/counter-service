{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ManageProjectScopedRoles",
      "Effect": "Allow",
      "Action": [
        "iam:GetRole",
        "iam:CreateRole",
        "iam:DeleteRole",
        "iam:UpdateRole",
        "iam:UpdateAssumeRolePolicy",
        "iam:TagRole",
        "iam:UntagRole",
        "iam:ListRoleTags",
        "iam:PutRolePolicy",
        "iam:DeleteRolePolicy",
        "iam:GetRolePolicy",
        "iam:ListRolePolicies",
        "iam:AttachRolePolicy",
        "iam:DetachRolePolicy",
        "iam:ListAttachedRolePolicies",
        "iam:PassRole"
      ],
      "Resource": [
        "arn:${partition}:iam::${account_id}:role/${cluster_name}-*",
        "arn:${partition}:iam::${account_id}:role/default-eks-node-group-*"
      ]
    },
    {
      "Sid": "ManageProjectScopedCustomerPolicies",
      "Effect": "Allow",
      "Action": [
        "iam:GetPolicy",
        "iam:GetPolicyVersion",
        "iam:CreatePolicy",
        "iam:DeletePolicy",
        "iam:CreatePolicyVersion",
        "iam:DeletePolicyVersion",
        "iam:ListPolicyVersions",
        "iam:TagPolicy",
        "iam:UntagPolicy",
        "iam:ListPolicyTags",
        "iam:ListEntitiesForPolicy"
      ],
      "Resource": [
        "arn:${partition}:iam::${account_id}:policy/${cluster_name}-*",
        "arn:${partition}:iam::${account_id}:policy/AmazonEKS_*"
      ]
    },
    {
      "Sid": "ReadAWSManagedPolicies",
      "Effect": "Allow",
      "Action": [
        "iam:GetPolicy",
        "iam:GetPolicyVersion"
      ],
      "Resource": "arn:${partition}:iam::aws:policy/*"
    },
    {
      "Sid": "ManageOIDCProviders",
      "Effect": "Allow",
      "Action": [
        "iam:GetOpenIDConnectProvider",
        "iam:CreateOpenIDConnectProvider",
        "iam:DeleteOpenIDConnectProvider",
        "iam:UpdateOpenIDConnectProviderThumbprint",
        "iam:AddClientIDToOpenIDConnectProvider",
        "iam:RemoveClientIDFromOpenIDConnectProvider",
        "iam:TagOpenIDConnectProvider",
        "iam:UntagOpenIDConnectProvider",
        "iam:ListOpenIDConnectProviders"
      ],
      "Resource": "arn:${partition}:iam::${account_id}:oidc-provider/*"
    },
    {
      "Sid": "CreateServiceLinkedRoles",
      "Effect": "Allow",
      "Action": "iam:CreateServiceLinkedRole",
      "Resource": "arn:${partition}:iam::${account_id}:role/aws-service-role/*"
    },
    {
      "Sid": "GlobalReadForPlanRefresh",
      "Effect": "Allow",
      "Action": [
        "iam:ListRoles",
        "iam:ListPolicies",
        "iam:ListInstanceProfiles",
        "iam:ListAccountAliases"
      ],
      "Resource": "*"
    }
  ]
}
